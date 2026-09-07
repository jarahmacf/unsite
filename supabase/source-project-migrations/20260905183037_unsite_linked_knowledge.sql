-- Linked, reviewed knowledge. Existing releases remain immutable and readable.
create function unsite_private.valid_knowledge_context(c jsonb) returns boolean
language plpgsql immutable security invoker set search_path='' as $$
declare x jsonb; k text;
begin
  if c is null or jsonb_typeof(c)<>'object' or pg_column_size(c)>12000 then return false; end if;
  if exists(select 1 from jsonb_object_keys(c) k where k not in ('summary','aliases','topics','status','as_of')) then return false; end if;
  if jsonb_typeof(c->'summary') is distinct from 'string' or length(c->>'summary')>1200 or coalesce(c->>'status','') not in ('unspecified','current','historical','uncertain') then return false; end if;
  foreach k in array array['aliases','topics'] loop
    if jsonb_typeof(c->k) is distinct from 'array' or jsonb_array_length(c->k)>20 then return false; end if;
    for x in select value from jsonb_array_elements(c->k) loop
      if jsonb_typeof(x)<>'string' or length(btrim(x#>>'{}')) not between 1 and 100 then return false; end if;
    end loop;
  end loop;
  if not(c ? 'as_of') then return false; end if;
  if c->'as_of'<>'null'::jsonb then
    if jsonb_typeof(c->'as_of')<>'string' or (c->>'as_of')!~'^\d{4}-\d{2}-\d{2}$' then return false; end if;
    perform (c->>'as_of')::date;
  end if;
  return true;
exception when others then return false;
end $$;
revoke all on function unsite_private.valid_knowledge_context(jsonb) from public,anon;
grant execute on function unsite_private.valid_knowledge_context(jsonb) to authenticated,service_role;
alter table public.unsite_spaces drop constraint unsite_spaces_kind_check;
alter table public.unsite_spaces add constraint unsite_spaces_kind_check check(kind in ('person','business','project','collection'));
alter table public.unsite_records add column context jsonb not null default '{"summary":"","aliases":[],"topics":[],"status":"unspecified","as_of":null}' check(unsite_private.valid_knowledge_context(context));
alter table public.unsite_candidates add column context jsonb not null default '{"summary":"","aliases":[],"topics":[],"status":"unspecified","as_of":null}' check(unsite_private.valid_knowledge_context(context));
alter table public.unsite_candidates add column suggested_links jsonb not null default '[]' check(jsonb_typeof(suggested_links)='array' and jsonb_array_length(suggested_links)<=20 and pg_column_size(suggested_links)<=70000);
create table public.unsite_record_links (
  space_id uuid not null,record_id uuid not null,target_id uuid not null,
  relation text not null check(relation in ('related_to','part_of','created_by','depends_on','documents','supersedes')),
  primary key(space_id,record_id,relation,target_id),check(record_id<>target_id),
  foreign key(space_id,record_id) references public.unsite_records(space_id,id) on delete cascade,
  foreign key(space_id,target_id) references public.unsite_records(space_id,id) on delete cascade
);
create index unsite_record_links_target on public.unsite_record_links(space_id,target_id);
create table public.unsite_record_evidence (
  space_id uuid not null,record_id uuid not null,candidate_id uuid not null,record_revision integer not null,recorded_at timestamptz not null default now(),
  primary key(space_id,record_id,candidate_id,record_revision),
  foreign key(space_id,record_id) references public.unsite_records(space_id,id) on delete cascade,
  foreign key(space_id,candidate_id) references public.unsite_candidates(space_id,id) on delete cascade
);
create index unsite_record_evidence_candidate on public.unsite_record_evidence(space_id,candidate_id);
insert into public.unsite_record_evidence(space_id,record_id,candidate_id,record_revision)
select space_id,id,candidate_id,revision from public.unsite_records where candidate_id is not null;
create table public.unsite_retrieval_cases (
  id uuid primary key default gen_random_uuid(),space_id uuid not null references public.unsite_spaces on delete cascade,
  question text not null check(length(btrim(question)) between 2 and 300),expected_record_id uuid,
  expectation text not null check(expectation in ('find','no_match')),request_id uuid not null,created_at timestamptz not null default now(),
  unique(space_id,request_id),foreign key(space_id,expected_record_id) references public.unsite_records(space_id,id),
  check((expectation='find' and expected_record_id is not null) or (expectation='no_match' and expected_record_id is null))
);
create index unsite_retrieval_cases_record on public.unsite_retrieval_cases(space_id,expected_record_id);
do $$ declare t text; begin
  foreach t in array array['unsite_record_links','unsite_record_evidence','unsite_retrieval_cases'] loop
    execute format('alter table public.%I enable row level security',t);
    execute format('revoke all on public.%I from public,anon,authenticated',t);
    execute format('grant select on public.%I to authenticated',t);
    execute format('grant all on public.%I to service_role',t);
    execute format('create policy member_read on public.%I for select to authenticated using (unsite_private.is_member(space_id))',t);
  end loop;
end $$;

create function unsite_private.knowledge_snapshot(target uuid) returns jsonb
language sql stable security invoker set search_path='' as $$
  select jsonb_build_object('source_revision',sp.content_revision,'snapshot',jsonb_build_object(
    'schema_version','2.1','id',sp.id,'name',sp.name,'kind',sp.kind,'description',sp.description,'contact_email',nullif(sp.contact_email,''),
    'records',coalesce((select jsonb_agg(jsonb_build_object('id',r.id,'kind',r.kind,'title',r.title,'text',r.text,'fields',r.fields,'context',r.context,'source_url',r.public_source_url,'revision',r.revision,'updated_at',r.updated_at,
      'links',coalesce((select jsonb_agg(jsonb_build_object('target_id',l.target_id,'relation',l.relation) order by l.relation,l.target_id) from public.unsite_record_links l join public.unsite_records target_record on target_record.space_id=l.space_id and target_record.id=l.target_id and target_record.active where l.space_id=sp.id and l.record_id=r.id),'[]'::jsonb)) order by r.kind,r.title,r.id)
      from public.unsite_records r where r.space_id=sp.id and r.active),'[]'::jsonb)))
    from public.unsite_spaces sp where sp.id=target and unsite_private.is_member(sp.id);
$$;
revoke all on function unsite_private.knowledge_snapshot(uuid) from public,anon;
grant execute on function unsite_private.knowledge_snapshot(uuid) to authenticated;
create function public.unsite_knowledge_snapshot(space_id uuid) returns jsonb language sql stable security invoker set search_path='' as $$select unsite_private.knowledge_snapshot(space_id);$$;
revoke all on function public.unsite_knowledge_snapshot(uuid) from public,anon;
grant execute on function public.unsite_knowledge_snapshot(uuid) to authenticated;

-- Candidate matching suggests comparisons; it never merges identities or chooses a winning fact.
create function public.unsite_compare_candidate(candidate_id uuid) returns jsonb language sql stable security invoker set search_path='' as $$
  with c as (select * from public.unsite_candidates where id=candidate_id),
  candidates as (
    select r.id,r.title,r.kind,r.text,r.fields,r.context,r.revision,r.active,'record' as origin from public.unsite_records r,c where r.space_id=c.space_id and r.kind=c.kind
    union all
    select r.id,r.title,r.kind,r.text,r.fields,r.context,r.revision,true,'candidate' from public.unsite_candidates r,c where r.space_id=c.space_id and r.kind=c.kind and r.id<>c.id and r.status='proposed'
  ), scored as (
    select r.*,case when lower(btrim(r.title))=lower(btrim(c.title)) or r.context->'aliases' ? c.title or c.context->'aliases' ? r.title then 1.0 else
      (select count(distinct t)::numeric/greatest(1,(select count(distinct q) from regexp_split_to_table(lower(c.title),'\W+') q where length(q)>2)) from regexp_split_to_table(lower(c.title),'\W+') t where length(t)>2 and t=any(regexp_split_to_array(lower(r.title),'\W+'))) end as similarity
    from candidates r,c
  ) select coalesce(jsonb_agg(to_jsonb(s)),'[]'::jsonb) from (select * from scored where similarity>=0.6 order by similarity desc,origin desc,id limit 8) s;
$$;
revoke all on function public.unsite_compare_candidate(uuid) from public,anon;
grant execute on function public.unsite_compare_candidate(uuid) to authenticated;

create function unsite_private.retrieval_case_command(action text,p jsonb) returns jsonb language plpgsql security definer set search_path='' as $$
declare sid uuid:=(p->>'space_id')::uuid; uid uuid:=auth.uid(); result jsonb;
begin
  if uid is null or not unsite_private.is_member(sid,array['owner','editor']) then raise exception 'Access denied' using errcode='42501'; end if;
  perform 1 from public.unsite_spaces where id=sid for update;
  if action='save_retrieval_case' then
    select to_jsonb(c.*) into result from public.unsite_retrieval_cases c where space_id=sid and request_id=(p->>'request_id')::uuid;
    if found then return result; end if;
    if (select count(*) from public.unsite_retrieval_cases where space_id=sid)>=20 then raise exception 'Retrieval case limit reached'; end if;
    insert into public.unsite_retrieval_cases(space_id,question,expectation,expected_record_id,request_id) values(sid,p->>'question',p->>'expectation',(p->>'expected_record_id')::uuid,(p->>'request_id')::uuid) returning to_jsonb(unsite_retrieval_cases.*) into result;
  elsif action='delete_retrieval_case' then
    delete from public.unsite_retrieval_cases where space_id=sid and id=(p->>'case_id')::uuid returning jsonb_build_object('id',id) into result;
  else raise exception 'Unknown command'; end if;
  return coalesce(result,'{}'::jsonb);
end $$;
revoke all on function unsite_private.retrieval_case_command(text,jsonb) from public,anon;
grant execute on function unsite_private.retrieval_case_command(text,jsonb) to authenticated;
create function public.unsite_retrieval_case_command(action text,payload jsonb) returns jsonb language sql security invoker set search_path='' as $$select unsite_private.retrieval_case_command(action,payload);$$;
revoke all on function public.unsite_retrieval_case_command(text,jsonb) from public,anon;
grant execute on function public.unsite_retrieval_case_command(text,jsonb) to authenticated;

create or replace function unsite_private.command(action text,p jsonb) returns jsonb
language plpgsql security definer set search_path='' as $$
declare
  uid uuid := auth.uid(); sid uuid; rid uuid; source_id uuid; version_id uuid; next_version integer;
  sp public.unsite_spaces; cand public.unsite_candidates; job public.unsite_jobs; rec public.unsite_records;
  release public.unsite_releases; v public.unsite_source_versions;
  result jsonb; snapshot jsonb; storage_name text; actual_size bigint; link jsonb;
begin
  if uid is null then raise exception 'Access denied' using errcode='42501'; end if;
  if pg_column_size(p)>1000000 then raise exception 'Request too large'; end if;
  if action='create_space' then
    -- Serialise the per-account limit and idempotency check.
    perform pg_advisory_xact_lock(hashtextextended(uid::text,0));
    select * into sp from public.unsite_spaces where owner_id=uid and request_id=(p->>'request_id')::uuid;
    if found then return to_jsonb(sp); end if;
    if (select count(*) from public.unsite_spaces where owner_id=uid)>=10 then raise exception 'Workspace limit reached'; end if;
    insert into public.unsite_spaces(owner_id,name,kind,request_id) values(uid,btrim(p->>'name'),p->>'kind',(p->>'request_id')::uuid) returning * into sp;
    insert into public.unsite_memberships(space_id,user_id,role) values(sp.id,uid,'owner');
    insert into public.unsite_events(space_id,actor_id,action) values(sp.id,uid,'presence.created');
    return to_jsonb(sp);
  end if;
  sid := (p->>'space_id')::uuid;
  if not unsite_private.is_member(sid,array['owner','editor']) then raise exception 'Access denied' using errcode='42501'; end if;
  select * into sp from public.unsite_spaces where id=sid for update;
  if not found then raise exception 'Workspace not found'; end if;
  if action in ('publish_release','rollback_release','unpublish') and not unsite_private.is_member(sid,array['owner']) then raise exception 'Access denied' using errcode='42501'; end if;

  if action='update_space' then
    if sp.content_revision is distinct from (p->>'revision')::integer then raise exception 'Record changed'; end if;
    update public.unsite_spaces set name=btrim(p->>'name'),description=coalesce(p->>'description',''),contact_email=coalesce(p->>'contact_email',''),content_revision=content_revision+1 where id=sid returning to_jsonb(unsite_spaces.*) into result;
  elsif action='source_intake' then
    select * into v from public.unsite_source_versions where space_id=sid and request_id=(p->>'request_id')::uuid;
    if found then return to_jsonb(v); end if;
    if (select count(*) from public.unsite_source_versions where space_id=sid)>=500 then raise exception 'Workspace limit reached'; end if;
    if p->>'kind'='text' and length(btrim(coalesce(p->>'text_content','')))=0 then raise exception 'Empty source'; end if;
    if p->>'kind'='url' and coalesce(p->>'origin_url','') not like 'https://%' then raise exception 'Invalid URL'; end if;
    if p->>'kind'='file' and (coalesce(p->>'mime_type','') not in ('text/plain','text/markdown','application/json','application/pdf') or (p->>'byte_size')::bigint<1) then raise exception 'Invalid file'; end if;
    source_id := (p->>'source_id')::uuid;
    if source_id is null then
      insert into public.unsite_sources(space_id,title,kind,origin_url,created_by) values(sid,p->>'title',p->>'kind',nullif(p->>'origin_url',''),uid) returning id into source_id;
    else
      if not exists(select 1 from public.unsite_sources where id=source_id and space_id=sid and archived_at is null and kind=p->>'kind' and origin_url is not distinct from nullif(p->>'origin_url','')) then raise exception 'Source not found'; end if;
    end if;
    select coalesce(max(version),0)+1 into next_version from public.unsite_source_versions where unsite_source_versions.source_id=command.source_id;
    version_id := gen_random_uuid();
    if p->>'kind'='file' then storage_name := sid::text||'/'||version_id::text||'/original'; end if;
    insert into public.unsite_source_versions(id,space_id,source_id,version,request_id,storage_path,mime_type,byte_size,text_content)
      values(version_id,sid,source_id,next_version,(p->>'request_id')::uuid,storage_name,case when p->>'kind'='url' then 'text/html' else coalesce(p->>'mime_type','text/plain') end,coalesce((p->>'byte_size')::bigint,0),case when p->>'kind'='text' then p->>'text_content' else null end) returning * into v;
    if storage_name is null then insert into public.unsite_jobs(space_id,source_version_id) values(sid,version_id); end if;
    result := to_jsonb(v);
  elsif action='complete_upload' then
    select * into v from public.unsite_source_versions where id=(p->>'version_id')::uuid and space_id=sid;
    if not found or v.storage_path is null or exists(select 1 from public.unsite_sources where id=v.source_id and archived_at is not null) then raise exception 'Source not found'; end if;
    select (metadata->>'size')::bigint into actual_size from storage.objects where bucket_id='unsite-sources' and name=v.storage_path;
    if actual_size is null or actual_size<>v.byte_size then raise exception 'Upload is not complete'; end if;
    insert into public.unsite_jobs(space_id,source_version_id) values(sid,v.id) on conflict(source_version_id) do nothing;
    select to_jsonb(j.*) into result from public.unsite_jobs j where j.source_version_id=v.id;
  elsif action in ('retry_job','cancel_job') then
    select * into job from public.unsite_jobs where id=(p->>'job_id')::uuid and space_id=sid for update;
    if not found then raise exception 'Source not found'; end if;
    if action='retry_job' then
      if job.status='running' then raise exception 'Job is already running'; end if;
      if job.status='completed' then return to_jsonb(job); end if;
      if exists(select 1 from public.unsite_source_versions v join public.unsite_sources s on s.id=v.source_id where v.id=job.source_version_id and s.archived_at is not null) then raise exception 'Source not found'; end if;
      update public.unsite_jobs set status='queued',stage='waiting',attempts=0,run_after=now(),error_code=null,error_message=null,lease_token=null,leased_until=null,updated_at=now() where id=job.id returning to_jsonb(unsite_jobs.*) into result;
    else
      update public.unsite_jobs set status='cancelled',stage='cancelled',lease_token=null,leased_until=null,updated_at=now() where id=job.id and status<>'completed' returning to_jsonb(unsite_jobs.*) into result;
    end if;
  elsif action='archive_source' then
    update public.unsite_sources set archived_at=coalesce(archived_at,now()) where id=(p->>'source_id')::uuid and space_id=sid returning id into source_id;
    if source_id is null then raise exception 'Source not found'; end if;
    update public.unsite_jobs set status='cancelled',stage='cancelled',lease_token=null,leased_until=null,updated_at=now() where space_id=sid and source_version_id in (select id from public.unsite_source_versions where unsite_source_versions.source_id=command.source_id) and status not in ('completed','cancelled');
    result := jsonb_build_object('id',source_id);
  elsif action='review_candidate' then
    select * into cand from public.unsite_candidates where id=(p->>'candidate_id')::uuid and space_id=sid for update;
    if not found then raise exception 'Candidate not found'; end if;
    if cand.revision is distinct from (p->>'revision')::integer or cand.status<>'proposed' then raise exception 'Record changed'; end if;
    if p->>'decision' not in ('accept','exclude') or p->>'decision' is null then raise exception 'Invalid decision'; end if;
    if p->>'decision'='accept' then
      if p->>'record_id' is not null then
        select * into rec from public.unsite_records where id=(p->>'record_id')::uuid and space_id=sid for update;
        if not found or rec.revision<>(p->>'record_revision')::integer or p->>'record_revision' is null then raise exception 'Record changed'; end if;
        update public.unsite_records set candidate_id=cand.id,kind=p->>'kind',title=p->>'title',text=p->>'text',fields=p->'fields',context=coalesce(p->'context',context),public_source_url=nullif(p->>'public_source_url',''),revision=revision+1,active=true,updated_at=now() where id=rec.id returning id into rid;
      else
        insert into public.unsite_records(space_id,candidate_id,kind,title,text,fields,context,public_source_url,created_by) values(sid,cand.id,p->>'kind',p->>'title',p->>'text',p->'fields',coalesce(p->'context',cand.context),nullif(p->>'public_source_url',''),uid) returning id into rid;
      end if;
      update public.unsite_spaces set content_revision=content_revision+1 where id=sid;
    end if;
    update public.unsite_candidates set status=case when p->>'decision'='accept' then 'accepted' else 'excluded' end,revision=revision+1 where id=cand.id;
    result := jsonb_build_object('id',cand.id,'record_id',rid);
  elsif action in ('create_record','edit_record') then
    if action='edit_record' then
      select * into rec from public.unsite_records where id=(p->>'record_id')::uuid and space_id=sid for update;
      if not found or rec.revision<>(p->>'revision')::integer or p->>'revision' is null then raise exception 'Record changed'; end if;
      update public.unsite_records set kind=p->>'kind',title=p->>'title',text=p->>'text',fields=p->'fields',context=coalesce(p->'context',context),public_source_url=nullif(p->>'public_source_url',''),active=(p->>'active')::boolean,revision=revision+1,updated_at=now() where id=rec.id returning to_jsonb(unsite_records.*) into result;
    else
      if p->>'request_id' is null then raise exception 'Request ID required'; end if;
      select to_jsonb(r.*) into result from public.unsite_records r where r.space_id=sid and r.request_id=(p->>'request_id')::uuid;
      if found then return result; end if;
      insert into public.unsite_records(space_id,kind,title,text,fields,context,public_source_url,created_by,request_id) values(sid,p->>'kind',p->>'title',p->>'text',p->'fields',coalesce(p->'context','{"summary":"","aliases":[],"topics":[],"status":"unspecified","as_of":null}'::jsonb),nullif(p->>'public_source_url',''),uid,(p->>'request_id')::uuid) returning to_jsonb(unsite_records.*) into result;
    end if;
    update public.unsite_spaces set content_revision=content_revision+1 where id=sid;
  elsif action='publish_release' then
    if coalesce((p->>'reviewed')::boolean,false) is not true then raise exception 'Review the publication'; end if;
    select * into release from public.unsite_releases where space_id=sid and request_id=(p->>'request_id')::uuid;
    if found then return to_jsonb(release)-'data'; end if;
    if sp.content_revision<>(p->>'revision')::integer or p->>'revision' is null then raise exception 'Record changed'; end if;
    if not exists(select 1 from public.unsite_records where space_id=sid and active) then raise exception 'No approved content'; end if;
    snapshot := unsite_private.knowledge_snapshot(sid)->'snapshot';
    if length(snapshot::text)>8000000 or jsonb_array_length(snapshot->'records')>1000 then raise exception 'Publication limit reached'; end if;
    insert into public.unsite_releases(space_id,revision,source_revision,data,summary,request_id,created_by)
      values(sid,(select coalesce(max(revision),0)+1 from public.unsite_releases where space_id=sid),sp.content_revision,snapshot,coalesce(p->>'summary',''),(p->>'request_id')::uuid,uid) returning * into release;
    update public.unsite_spaces set active_release_id=release.id where id=sid;
    result := to_jsonb(release)-'data';
  elsif action='rollback_release' then
    if coalesce((p->>'reviewed')::boolean,false) is not true then raise exception 'Review the publication'; end if;
    select * into release from public.unsite_releases where id=(p->>'release_id')::uuid and space_id=sid;
    if not found then raise exception 'Access denied'; end if;
    update public.unsite_spaces set active_release_id=release.id where id=sid;
    result := to_jsonb(release)-'data';
  elsif action='unpublish' then
    if coalesce((p->>'reviewed')::boolean,false) is not true then raise exception 'Review the publication'; end if;
    update public.unsite_spaces set active_release_id=null where id=sid;
    result := jsonb_build_object('id',sid);
  else raise exception 'Unknown command';
  end if;
  if action in ('create_record','edit_record') or (action='review_candidate' and p->>'decision'='accept') then
    rid := case when action='review_candidate' then (result->>'record_id')::uuid else (result->>'id')::uuid end;
    if p ? 'links' then
      if jsonb_typeof(p->'links') is distinct from 'array' or jsonb_array_length(p->'links')>30 then raise exception 'Invalid relationships'; end if;
      delete from public.unsite_record_links where space_id=sid and record_id=rid;
      for link in select value from jsonb_array_elements(p->'links') loop
        if not exists(select 1 from public.unsite_records where space_id=sid and id=(link->>'target_id')::uuid and active) then raise exception 'Relationship target not found'; end if;
        insert into public.unsite_record_links(space_id,record_id,target_id,relation) values(sid,rid,(link->>'target_id')::uuid,link->>'relation') on conflict do nothing;
      end loop;
    end if;
    if action='review_candidate' then
      insert into public.unsite_record_evidence(space_id,record_id,candidate_id,record_revision) select sid,rid,cand.id,revision from public.unsite_records where id=rid;
    end if;
  end if;
  insert into public.unsite_events(space_id,actor_id,action,details) values(sid,uid,action,jsonb_strip_nulls(jsonb_build_object('id',result->>'id','decision',p->>'decision','record_id',result->>'record_id')));
  return coalesce(result,'{}');
end $$;

create or replace function public.unsite_job_result(job_id uuid,lease uuid,result jsonb) returns boolean language plpgsql security invoker set search_path='' as $$
declare j public.unsite_jobs; item jsonb; n integer:=0; warnings jsonb;
begin
  perform 1 from public.unsite_spaces where id=(select space_id from public.unsite_jobs where id=job_id) for key share;
  select * into j from public.unsite_jobs where id=job_id for update;
  if not found or j.status<>'running' or j.lease_token is distinct from lease or j.leased_until<now() then return false; end if;
  if result->>'mode'='parsed' then
    update public.unsite_source_versions set extracted_text=result->>'text',content_hash=result->>'hash' where id=j.source_version_id;
    update public.unsite_jobs set chunk_count=(result->>'chunks')::integer,stage='preparing',progress=10,leased_until=now()+interval '150 seconds',updated_at=now() where id=j.id;
  elsif result->>'mode'='chunk' then
    if (result->>'cursor')::integer is distinct from j.cursor then return false; end if;
    if not exists(select 1 from public.unsite_ai_attempts d join public.unsite_ai_authorizations a on a.id=d.authorization_id
      where d.id=(result->>'dispatch_id')::uuid and d.job_id=j.id and d.lease_token=lease and d.chunk_index=j.cursor and d.status='succeeded' and a.source_version_id=j.source_version_id and a.revoked_at is null) then return false; end if;
    for item in select value from jsonb_array_elements(result->'candidates') loop
      warnings:=coalesce(item->'warnings','[]');
      if exists(select 1 from public.unsite_records r where r.space_id=j.space_id and r.active and r.kind=item->>'kind' and lower(r.title)=lower(item->>'title'))
        or exists(select 1 from public.unsite_candidates c where c.space_id=j.space_id and c.kind=item->>'kind' and lower(c.title)=lower(item->>'title') and c.status='proposed') then
        warnings:=warnings||'"A similar entry exists. Compare it before adding or replacing content."'::jsonb;
      end if;
      insert into public.unsite_candidates(space_id,source_version_id,job_id,chunk_index,item_index,kind,title,text,fields,context,suggested_links,evidence,warnings)
        values(j.space_id,j.source_version_id,j.id,j.cursor,n,item->>'kind',item->>'title',item->>'text',item->'fields',coalesce(item->'context','{"summary":"","aliases":[],"topics":[],"status":"unspecified","as_of":null}'::jsonb),coalesce(item->'suggested_links','[]'::jsonb),item->'evidence',warnings) on conflict do nothing;
      n:=n+1;
    end loop;
    update public.unsite_jobs set cursor=cursor+1,status=case when cursor+1>=chunk_count then 'completed' else 'queued' end,
      stage=case when cursor+1>=chunk_count then 'ready for review' else 'preparing' end,
      progress=case when cursor+1>=chunk_count then 100 else least(95,10+(85*(cursor+1)/greatest(chunk_count,1))) end,
      attempts=0,lease_token=null,leased_until=null,run_after=now(),updated_at=now(),error_code=null,error_message=null where id=j.id;
    if j.cursor+1>=j.chunk_count then insert into public.unsite_events(space_id,action,details) values(j.space_id,'source.prepared',jsonb_build_object('id',j.source_version_id)); end if;
  elsif result->>'mode'='error' then
    update public.unsite_jobs set status=case when result->>'disposition'='retry' and attempts<max_attempts then 'queued' when result->>'disposition'='blocked' then 'blocked' else 'failed' end,
      stage=case when result->>'code'='AI_APPROVAL_REQUIRED' then 'ready to prepare' when result->>'code'='PROVIDER_UNCERTAIN' then 'review needed' when result->>'disposition'='blocked' then 'setup needed' else 'interrupted' end,
      error_code=left(result->>'code',100),error_message=left(result->>'message',1000),run_after=now()+make_interval(secs=>least(300,30*attempts)),lease_token=null,leased_until=null,updated_at=now() where id=j.id;
  else raise exception 'Unknown worker result'; end if;
  return true;
end $$;
