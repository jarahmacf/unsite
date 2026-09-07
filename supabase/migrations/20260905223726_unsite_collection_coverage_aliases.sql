create or replace function public.unsite_collection_result(p_task_id uuid,p_lease uuid,result jsonb) returns boolean language plpgsql security invoker set search_path='' as $$
declare r public.unsite_collection_runs;t public.unsite_collection_tasks;parent public.unsite_collection_tasks;o jsonb:=result->'output';item jsonb;batch jsonb;v jsonb;n integer:=0;expected text[];covered text[];allowed uuid[];target jsonb;
begin
  perform 1 from public.unsite_spaces where id=(select space_id from public.unsite_collection_tasks where id=p_task_id) for key share;
  select * into r from public.unsite_collection_runs where id=(select run_id from public.unsite_collection_tasks where id=p_task_id) for update;
  select * into t from public.unsite_collection_tasks where id=p_task_id for update;
  if not found or t.status<>'running' or t.lease_token is distinct from p_lease or t.leased_until<now() or r.status not in ('waiting','running') or r.revoked_at is not null then return false; end if;
  if exists(select 1 from public.unsite_collection_inputs i join public.unsite_source_versions sv on sv.id=i.source_version_id join public.unsite_sources s on s.id=sv.source_id where i.run_id=r.id and s.archived_at is not null) then
    update public.unsite_collection_tasks set status='blocked',lease_token=null,leased_until=null,error_code='SOURCE_ARCHIVED',error_message='A source was archived. Start another run with active sources.',updated_at=now() where id=t.id;
    update public.unsite_collection_runs set status='blocked',stage='Source needs attention',error_code='SOURCE_ARCHIVED',error_message='A source was archived. Start another run with active sources.',updated_at=now() where id=r.id;return false;
  end if;
  if result->>'mode'='error' then
    update public.unsite_collection_tasks set status=case when result->>'disposition'='retry' and attempts<3 then 'queued' else 'blocked' end,error_code=left(result->>'code',100),error_message=left(result->>'message',1000),lease_token=null,leased_until=null,run_after=now()+make_interval(secs=>30*attempts),updated_at=now() where id=t.id returning * into t;
    if t.status='blocked' then update public.unsite_collection_runs set status='blocked',stage='Paused',error_code=t.error_code,error_message=t.error_message,updated_at=now() where id=r.id; end if;
    return true;
  end if;
  if result->>'mode' is distinct from 'complete' or o is null or octet_length(o::text)>2000000 then raise exception 'Invalid collection checkpoint'; end if;
  if t.stage<>'plan' and not exists(select 1 from public.unsite_collection_attempts where id=(result->>'dispatch_id')::uuid and task_id=t.id and lease_token=p_lease and status='succeeded') then return false; end if;
  if t.stage='extract' then
    if jsonb_typeof(o->'candidates') is distinct from 'array' or jsonb_array_length(o->'candidates')>50 then raise exception 'Invalid extraction'; end if;
    allowed:=array[(t.input->>'segment_id')::uuid];
    if not exists(select 1 from public.unsite_evidence_segments e join public.unsite_collection_inputs i on i.source_version_id=e.source_version_id where i.run_id=r.id and e.id=any(allowed)) then raise exception 'Invalid source segment'; end if;
    for item in select value from jsonb_array_elements(o->'candidates') loop
      if not unsite_private.valid_collection_item(item,allowed) then raise exception 'Invalid source evidence'; end if;
    end loop;
  elsif t.stage='plan' then
    if jsonb_typeof(o->'batches') is distinct from 'array' or jsonb_array_length(o->'batches')>1000 then raise exception 'Invalid collection plan'; end if;
    select coalesce(array_agg(x.id::text||':'||(c.n-1)),'{}') into expected from public.unsite_collection_tasks x cross join lateral jsonb_array_elements(x.output->'candidates') with ordinality c(value,n) where x.run_id=r.id and x.stage='extract' and x.status='completed';
    select coalesce(array_agg(source_item.value),'{}') into covered from jsonb_array_elements(o->'batches') b cross join lateral jsonb_array_elements_text(b->'source_items') source_item(value);
    if cardinality(expected)>1000 or cardinality(expected)<>cardinality(covered) or not(expected<@covered and covered<@expected) then raise exception 'Collection plan must cover every source item once'; end if;
    for batch in select value from jsonb_array_elements(o->'batches') loop
      if jsonb_array_length(batch->'source_items') not between 1 and 20 or jsonb_typeof(batch->'record_ids') is distinct from 'array' or jsonb_array_length(batch->'record_ids')>4 then raise exception 'Invalid collection batch'; end if;
      if exists(select 1 from jsonb_array_elements_text(batch->'record_ids') id where not exists(select 1 from jsonb_array_elements(r.knowledge_snapshot->'records') rec where rec->>'id'=id)) then raise exception 'Invalid existing knowledge reference'; end if;
      insert into public.unsite_collection_tasks(run_id,space_id,stage,ordinal,input) values(r.id,r.space_id,'curate',n,batch);n:=n+1;
    end loop;
  elsif t.stage='curate' then
    if jsonb_typeof(o->'proposals') is distinct from 'array' or jsonb_array_length(o->'proposals')>40 or jsonb_typeof(o->'unresolved') is distinct from 'array' or jsonb_array_length(o->'unresolved')>20 or length(coalesce(o->>'summary',''))>2000 then raise exception 'Invalid curation'; end if;
    select array_agg(value) into expected from jsonb_array_elements_text(t.input->'source_items');
    select coalesce(array_agg(id),'{}') into covered from (select source_item.value id from jsonb_array_elements(o->'proposals') p cross join lateral jsonb_array_elements_text(p->'source_items') source_item(value) union all select unresolved.value->>'source_item_id' from jsonb_array_elements(o->'unresolved') unresolved(value)) ids;
    if not(expected<@covered and covered<@expected) then raise exception 'Curation must account for every source item'; end if;
    select array_agg(distinct (e->>'segment_id')::uuid) into allowed from public.unsite_collection_tasks x cross join lateral jsonb_array_elements(x.output->'candidates') with ordinality c(value,n) cross join lateral jsonb_array_elements(c.value->'evidence') e where x.run_id=r.id and x.stage='extract' and (x.id::text||':'||(c.n-1))=any(expected);
    for item in select value from jsonb_array_elements(o->'proposals') loop
      if jsonb_array_length(item->'source_items')<1 or not unsite_private.valid_collection_item(item,allowed) or length(coalesce(item->>'change_reason','')) not between 1 and 1500 then raise exception 'Invalid curated evidence'; end if;
      if item->>'suggested_record_id' is not null then
        select value into target from jsonb_array_elements(r.knowledge_snapshot->'records') where value->>'id'=item->>'suggested_record_id';
        if not found or target->'revision' is distinct from item->'suggested_record_revision' or not(t.input->'record_ids' ? (item->>'suggested_record_id')) then raise exception 'Invalid update target'; end if;
      elsif item->>'suggested_record_revision' is not null then raise exception 'Invalid update revision'; end if;
    end loop;
    for item in select value from jsonb_array_elements(o->'unresolved') loop
      if length(coalesce(item->>'reason','')) not between 1 and 1500 then raise exception 'Missing unresolved reason'; end if;
    end loop;
    insert into public.unsite_collection_tasks(run_id,space_id,stage,ordinal,input) values(r.id,r.space_id,'verify',t.ordinal,t.input||jsonb_build_object('curate_task_id',t.id));
  elsif t.stage='verify' then
    select * into parent from public.unsite_collection_tasks where id=(t.input->>'curate_task_id')::uuid and run_id=r.id and stage='curate' and status='completed';
    if not found or jsonb_typeof(o->'verdicts') is distinct from 'array' or jsonb_array_length(o->'verdicts')<>jsonb_array_length(parent.output->'proposals') then raise exception 'Incomplete verification'; end if;
    for item in select value from jsonb_array_elements(parent.output->'proposals') loop
      v:=o->'verdicts'->n;
      if (v->>'proposal_index')::integer is distinct from n or coalesce(v->>'verdict','') not in ('supported','needs_review','unsupported') or jsonb_typeof(v->'issues') is distinct from 'array' or jsonb_array_length(v->'issues')>10 or exists(select 1 from jsonb_array_elements(v->'issues') issue where jsonb_typeof(issue)<>'string' or length(issue#>>'{}') not between 1 and 1000) or (v->>'verdict'<>'supported' and jsonb_array_length(v->'issues')=0) then raise exception 'Invalid verification verdict'; end if;
      insert into public.unsite_candidates(space_id,collection_run_id,chunk_index,item_index,kind,title,text,fields,context,suggested_links,evidence,warnings,verification,suggested_record_id,suggested_record_revision,change_reason,review_ready)
        values(r.space_id,r.id,t.ordinal,n,item->>'kind',item->>'title',item->>'text',item->'fields',item->'context',item->'suggested_links',item->'evidence',item->'warnings',v-'proposal_index',(item->>'suggested_record_id')::uuid,(item->>'suggested_record_revision')::integer,item->>'change_reason',false);
      n:=n+1;
    end loop;
  end if;
  update public.unsite_collection_tasks set output=o,status='completed',lease_token=null,leased_until=null,error_code=null,error_message=null,updated_at=now() where id=t.id;
  if t.stage in ('plan','verify') and not exists(select 1 from public.unsite_collection_tasks where run_id=r.id and status<>'completed') then
    update public.unsite_candidates set review_ready=true where collection_run_id=r.id;
    update public.unsite_collection_runs set status='completed',stage='Ready for owner review',error_code=null,error_message=null,updated_at=now() where id=r.id;
    insert into public.unsite_events(space_id,action,details) values(r.space_id,'collection.prepared',jsonb_build_object('id',r.id));
  end if;
  return true;
end $$;
