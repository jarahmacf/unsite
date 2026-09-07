-- Collection runs share immutable source evidence and frozen owner-approved knowledge.
create table public.unsite_evidence_segments (
  id uuid primary key default gen_random_uuid(),space_id uuid not null,source_version_id uuid not null,
  ordinal integer not null check(ordinal>=0),start_char integer not null check(start_char>=0),end_char integer not null,
  text text not null check(length(text) between 1 and 12000),locator text not null,
  foreign key(space_id,source_version_id) references public.unsite_source_versions(space_id,id) on delete cascade,
  check(end_char>start_char and end_char-start_char=length(text)),unique(source_version_id,ordinal),unique(space_id,id)
);
create index unsite_segments_space_version on public.unsite_evidence_segments(space_id,source_version_id);
create function unsite_private.segment_source() returns trigger language plpgsql security definer set search_path='' as $$
begin
  if TG_OP='UPDATE' and old.extracted_text is not null and new.extracted_text is distinct from old.extracted_text then raise exception 'Parsed source versions are immutable'; end if;
  if new.extracted_text is not null then
    insert into public.unsite_evidence_segments(space_id,source_version_id,ordinal,start_char,end_char,text,locator)
      select new.space_id,new.id,n/12000,n,least(n+12000,length(new.extracted_text)),substr(new.extracted_text,n+1,12000),
        'Characters '||(n+1)||'–'||least(n+12000,length(new.extracted_text)) from generate_series(0,length(new.extracted_text)-1,12000) n on conflict(source_version_id,ordinal) do nothing;
  end if;
  return new;
end $$;
revoke all on function unsite_private.segment_source() from public,anon,authenticated;
create trigger unsite_source_segments after insert or update of extracted_text on public.unsite_source_versions for each row execute function unsite_private.segment_source();
insert into public.unsite_evidence_segments(space_id,source_version_id,ordinal,start_char,end_char,text,locator)
select v.space_id,v.id,n/12000,n,least(n+12000,length(v.extracted_text)),substr(v.extracted_text,n+1,12000),'Characters '||(n+1)||'–'||least(n+12000,length(v.extracted_text))
from public.unsite_source_versions v cross join lateral generate_series(0,length(v.extracted_text)-1,12000) n where v.extracted_text is not null;

create table public.unsite_collection_runs (
  id uuid primary key default gen_random_uuid(),space_id uuid not null references public.unsite_spaces(id) on delete cascade,
  goal text not null check(length(goal) between 1 and 1500),status text not null default 'waiting' check(status in ('waiting','running','blocked','completed','cancelled')),
  stage text not null default 'Waiting for source text',source_revision integer not null,knowledge_snapshot jsonb not null,
  max_requests integer not null check(max_requests between 1 and 200),authorized_by uuid not null references auth.users(id),authorized_at timestamptz not null default now(),
  disclosure_version text not null check(disclosure_version='openai-collection-preparation-2026-09-05'),revoked_at timestamptz,
  request_id uuid not null,error_code text,error_message text,created_at timestamptz not null default now(),updated_at timestamptz not null default now(),
  unique(space_id,id),unique(space_id,request_id)
);
create index unsite_collection_authorizer on public.unsite_collection_runs(authorized_by);
create unique index unsite_collection_active on public.unsite_collection_runs(space_id) where status in ('waiting','running','blocked');
create index unsite_collection_schedule on public.unsite_collection_runs(updated_at) where status in ('waiting','running');
create table public.unsite_collection_inputs (
  run_id uuid not null,space_id uuid not null,source_version_id uuid not null,
  primary key(run_id,source_version_id),
  foreign key(space_id,run_id) references public.unsite_collection_runs(space_id,id) on delete cascade,
  foreign key(space_id,source_version_id) references public.unsite_source_versions(space_id,id)
);
create index unsite_collection_inputs_space_run on public.unsite_collection_inputs(space_id,run_id);
create index unsite_collection_inputs_version on public.unsite_collection_inputs(space_id,source_version_id);
create table public.unsite_collection_tasks (
  id uuid primary key default gen_random_uuid(),run_id uuid not null,space_id uuid not null,
  stage text not null check(stage in ('extract','plan','curate','verify')),ordinal integer not null check(ordinal>=0),
  status text not null default 'queued' check(status in ('queued','running','blocked','completed','cancelled')),
  input jsonb not null default '{}',output jsonb,attempts integer not null default 0,lease_token uuid,leased_until timestamptz,
  run_after timestamptz not null default now(),error_code text,error_message text,created_at timestamptz not null default now(),updated_at timestamptz not null default now(),
  foreign key(space_id,run_id) references public.unsite_collection_runs(space_id,id) on delete cascade,
  unique(run_id,stage,ordinal),unique(space_id,id)
);
create index unsite_collection_tasks_space_run on public.unsite_collection_tasks(space_id,run_id,status);
create index unsite_collection_tasks_queue on public.unsite_collection_tasks(run_id,run_after,ordinal) where status='queued';
create table public.unsite_collection_attempts (
  id uuid primary key default gen_random_uuid(),run_id uuid not null,space_id uuid not null,task_id uuid not null,lease_token uuid not null,
  model text not null check(length(model) between 1 and 128),status text not null default 'in_flight' check(status in ('in_flight','succeeded','failed','uncertain')),
  provider_response_id text,input_tokens integer check(input_tokens>=0),output_tokens integer check(output_tokens>=0),
  started_at timestamptz not null default now(),finished_at timestamptz,
  foreign key(space_id,run_id) references public.unsite_collection_runs(space_id,id) on delete cascade,
  foreign key(space_id,task_id) references public.unsite_collection_tasks(space_id,id) on delete cascade,
  unique(task_id,lease_token)
);
create index unsite_collection_attempts_budget on public.unsite_collection_attempts(started_at,space_id);
create index unsite_collection_attempts_run on public.unsite_collection_attempts(space_id,run_id);
create index unsite_collection_attempts_task on public.unsite_collection_attempts(space_id,task_id);

alter table public.unsite_candidates add column review_ready boolean not null default true;
alter table public.unsite_candidates alter column source_version_id drop not null,alter column job_id drop not null;
alter table public.unsite_candidates add column collection_run_id uuid,add column verification jsonb,
  add column suggested_record_id uuid,add column suggested_record_revision integer,add column change_reason text;
alter table public.unsite_candidates add foreign key(space_id,collection_run_id) references public.unsite_collection_runs(space_id,id) on delete cascade,
  add foreign key(space_id,suggested_record_id) references public.unsite_records(space_id,id),
  add constraint unsite_candidate_origin check((collection_run_id is null and source_version_id is not null and job_id is not null) or (collection_run_id is not null and source_version_id is null and job_id is null)),
  add constraint unsite_candidate_collection_unique unique(collection_run_id,chunk_index,item_index);
create index unsite_candidates_collection on public.unsite_candidates(space_id,collection_run_id) where collection_run_id is not null;
create index unsite_candidates_suggested_record on public.unsite_candidates(space_id,suggested_record_id) where suggested_record_id is not null;

do $$ declare tab text; begin
  foreach tab in array array['unsite_evidence_segments','unsite_collection_runs','unsite_collection_inputs','unsite_collection_tasks','unsite_collection_attempts'] loop
    execute format('alter table public.%I enable row level security',tab);
    execute format('revoke all on public.%I from public,anon,authenticated',tab);
    execute format('grant all on public.%I to service_role',tab);
    execute format('grant select on public.%I to authenticated',tab);
    execute format('create policy member_read on public.%I for select to authenticated using (unsite_private.is_member(space_id))',tab);
  end loop;
end $$;

create function unsite_private.collection_command(action text,p jsonb) returns jsonb language plpgsql security definer set search_path='' as $$
declare uid uuid:=auth.uid();sid uuid:=(p->>'space_id')::uuid;r public.unsite_collection_runs;sp public.unsite_spaces;snapshot jsonb;ids uuid[];vid uuid;
begin
  if uid is null or not unsite_private.is_member(sid,array['owner','editor']) then raise exception 'Access denied' using errcode='42501'; end if;
  select * into sp from public.unsite_spaces where id=sid for update;
  if action='start_collection_run' then
    if (p->>'approved')::boolean is distinct from true or p->>'disclosure_version' is distinct from 'openai-collection-preparation-2026-09-05' then raise exception 'Review the collection AI disclosure'; end if;
    if p->>'request_id' is null then raise exception 'Request ID required'; end if;
    select * into r from public.unsite_collection_runs where space_id=sid and request_id=(p->>'request_id')::uuid;
    if found then return to_jsonb(r)-'knowledge_snapshot'; end if;
    if exists(select 1 from public.unsite_collection_runs where space_id=sid and status in ('waiting','running','blocked')) then raise exception 'Finish or stop the active collection run'; end if;
    if jsonb_typeof(p->'version_ids') is distinct from 'array' or jsonb_array_length(p->'version_ids') not between 1 and 8 then raise exception 'Select one to eight source versions'; end if;
    select array_agg(value::uuid) into ids from jsonb_array_elements_text(p->'version_ids');
    if cardinality(ids)<>(select count(distinct x) from unnest(ids) x) then raise exception 'Select each source version once'; end if;
    foreach vid in array ids loop
      if not exists(select 1 from public.unsite_source_versions v join public.unsite_sources s on s.id=v.source_id join public.unsite_jobs j on j.source_version_id=v.id where v.id=vid and v.space_id=sid and s.archived_at is null) then raise exception 'Source not found or upload incomplete'; end if;
    end loop;
    snapshot:=unsite_private.knowledge_snapshot(sid)->'snapshot';
    if jsonb_array_length(snapshot->'records')>200 or octet_length(snapshot::text)>1200000 then raise exception 'Collection knowledge limit reached'; end if;
    insert into public.unsite_collection_runs(space_id,goal,source_revision,knowledge_snapshot,max_requests,authorized_by,disclosure_version,request_id)
      values(sid,btrim(p->>'goal'),sp.content_revision,snapshot,(p->>'max_requests')::integer,uid,p->>'disclosure_version',(p->>'request_id')::uuid) returning * into r;
    insert into public.unsite_collection_inputs(run_id,space_id,source_version_id) select r.id,sid,x from unnest(ids) x;
  else
    select * into r from public.unsite_collection_runs where id=(p->>'run_id')::uuid and space_id=sid for update;
    if not found then raise exception 'Collection run not found'; end if;
    if action='cancel_collection_run' then
      if r.status='completed' then raise exception 'Collection run is already complete'; end if;
      update public.unsite_collection_runs set status='cancelled',stage='Stopped',revoked_at=coalesce(revoked_at,now()),updated_at=now() where id=r.id returning * into r;
      update public.unsite_collection_tasks set status='cancelled',lease_token=null,leased_until=null,updated_at=now() where run_id=r.id and status<>'completed';
      update public.unsite_collection_attempts set status='uncertain',finished_at=now() where run_id=r.id and status='in_flight';
    elsif action='resume_collection_run' then
      if r.status<>'blocked' or r.revoked_at is not null then raise exception 'Only a paused collection run can resume'; end if;
      if (p->>'retry_reviewed')::boolean is distinct from true then raise exception 'Review the retry notice'; end if;
      update public.unsite_collection_runs set status='waiting',stage='Resuming saved work',max_requests=(p->>'max_requests')::integer,error_code=null,error_message=null,updated_at=now() where id=r.id returning * into r;
      update public.unsite_collection_tasks set status='queued',attempts=0,lease_token=null,leased_until=null,run_after=now(),error_code=null,error_message=null,updated_at=now() where run_id=r.id and status='blocked';
    else raise exception 'Unknown command'; end if;
  end if;
  insert into public.unsite_events(space_id,actor_id,action,details) values(sid,uid,action,jsonb_build_object('id',r.id));
  return to_jsonb(r)-'knowledge_snapshot';
end $$;
revoke all on function unsite_private.collection_command(text,jsonb) from public,anon;
grant execute on function unsite_private.collection_command(text,jsonb) to authenticated;
create function public.unsite_collection_command(action text,payload jsonb) returns jsonb language sql security invoker set search_path='' as $$select unsite_private.collection_command(action,payload);$$;
revoke all on function public.unsite_collection_command(text,jsonb) from public,anon;
grant execute on function public.unsite_collection_command(text,jsonb) to authenticated;

-- One task per invocation. Space -> run -> task locks match cancellation and review.
create function public.unsite_claim_collection_task() returns jsonb language plpgsql security invoker set search_path='' as $$
declare candidate record;r public.unsite_collection_runs;t public.unsite_collection_tasks;n integer;
begin
  for candidate in select id,space_id from public.unsite_collection_runs where status in ('waiting','running') order by updated_at limit 20 loop
    perform 1 from public.unsite_spaces where id=candidate.space_id for key share;
    select * into r from public.unsite_collection_runs where id=candidate.id and status in ('waiting','running') for update skip locked;
    if not found then continue; end if;
    if exists(select 1 from public.unsite_collection_inputs i join public.unsite_source_versions v on v.id=i.source_version_id join public.unsite_sources s on s.id=v.source_id where i.run_id=r.id and s.archived_at is not null) then
      update public.unsite_collection_runs set status='blocked',stage='Source needs attention',error_code='SOURCE_ARCHIVED',error_message='A selected source was archived. Stop this run and start another with active sources.',updated_at=now() where id=r.id;continue;
    end if;
    update public.unsite_collection_attempts a set status='uncertain',finished_at=now() from public.unsite_collection_tasks task where task.run_id=r.id and a.task_id=task.id and a.status='in_flight' and (task.status<>'running' or task.leased_until<now() or task.lease_token is distinct from a.lease_token);
    update public.unsite_collection_tasks task set status='blocked',error_code='PROVIDER_UNCERTAIN',error_message='The AI request ended without a saved checkpoint. Retrying may incur another provider charge.',lease_token=null,leased_until=null,updated_at=now()
      where task.run_id=r.id and task.status='running' and task.leased_until<now() and exists(select 1 from public.unsite_collection_attempts a where a.task_id=task.id and a.lease_token=task.lease_token);
    update public.unsite_collection_tasks set status=case when attempts>=3 then 'blocked' else 'queued' end,error_code='INTERRUPTED',error_message='This step was interrupted. Its saved inputs are preserved.',lease_token=null,leased_until=null,updated_at=now() where run_id=r.id and status='running' and leased_until<now();
    if exists(select 1 from public.unsite_collection_tasks where run_id=r.id and status='blocked') then
      select * into t from public.unsite_collection_tasks where run_id=r.id and status='blocked' order by updated_at limit 1;
      update public.unsite_collection_runs set status='blocked',stage='Paused',error_code=t.error_code,error_message=t.error_message,updated_at=now() where id=r.id;continue;
    end if;
    if exists(select 1 from public.unsite_collection_tasks where run_id=r.id and status='running') then continue; end if;
    if not exists(select 1 from public.unsite_collection_tasks where run_id=r.id) then
      if exists(select 1 from public.unsite_collection_inputs i join public.unsite_source_versions v on v.id=i.source_version_id join public.unsite_jobs j on j.source_version_id=v.id where i.run_id=r.id and v.extracted_text is null and j.status in ('blocked','failed','cancelled','completed')) then
        update public.unsite_collection_runs set status='blocked',stage='Source needs attention',error_code='SOURCE_NOT_PARSED',error_message='A selected source could not be read. Open its version, retry reading or replace it, then resume this run.',updated_at=now() where id=r.id;continue;
      end if;
      if exists(select 1 from public.unsite_collection_inputs i join public.unsite_source_versions v on v.id=i.source_version_id where i.run_id=r.id and v.extracted_text is null) then continue; end if;
      select count(*) into n from public.unsite_evidence_segments e join public.unsite_collection_inputs i on i.source_version_id=e.source_version_id where i.run_id=r.id;
      if n not between 1 and 80 then
        update public.unsite_collection_runs set status='blocked',stage='Collection limit reached',error_code='COLLECTION_SIZE',error_message='Use a smaller selection: this version supports up to 80 passages, approximately 960,000 characters per run.',updated_at=now() where id=r.id;continue;
      end if;
      insert into public.unsite_collection_tasks(run_id,space_id,stage,ordinal,input)
        select r.id,r.space_id,'extract',(row_number() over(order by e.ordinal,e.source_version_id)-1)::integer,jsonb_build_object('segment_id',e.id)
        from public.unsite_evidence_segments e join public.unsite_collection_inputs i on i.source_version_id=e.source_version_id where i.run_id=r.id;
    end if;
    if not exists(select 1 from public.unsite_collection_tasks where run_id=r.id and stage='extract' and status<>'completed') and not exists(select 1 from public.unsite_collection_tasks where run_id=r.id and stage='plan') then
      insert into public.unsite_collection_tasks(run_id,space_id,stage,ordinal) values(r.id,r.space_id,'plan',0);
    end if;
    select * into t from public.unsite_collection_tasks where run_id=r.id and status='queued' and run_after<=now() order by case stage when 'extract' then 0 when 'plan' then 1 when 'curate' then 2 else 3 end,ordinal for update skip locked limit 1;
    if not found then continue; end if;
    update public.unsite_collection_tasks set status='running',attempts=attempts+1,lease_token=gen_random_uuid(),leased_until=now()+interval '150 seconds',updated_at=now() where id=t.id returning * into t;
    update public.unsite_collection_runs set status='running',stage=case t.stage when 'extract' then 'Reading source evidence' when 'plan' then 'Grouping related material' when 'curate' then 'Curating knowledge' else 'Checking proposals' end,updated_at=now() where id=r.id;
    return to_jsonb(t);
  end loop;
  return null;
end $$;

create function public.unsite_collection_dispatch(p_task_id uuid,p_lease uuid,p_model text) returns jsonb language plpgsql security invoker set search_path='' as $$
declare r public.unsite_collection_runs;t public.unsite_collection_tasks;request_id uuid;
begin
  perform 1 from public.unsite_spaces where id=(select space_id from public.unsite_collection_tasks where id=p_task_id) for key share;
  select * into r from public.unsite_collection_runs where id=(select run_id from public.unsite_collection_tasks where id=p_task_id) for update;
  select * into t from public.unsite_collection_tasks where id=p_task_id for update;
  if not found or t.status<>'running' or t.lease_token is distinct from p_lease or t.leased_until<now() then return jsonb_build_object('allowed',false,'reason','STALE_LEASE'); end if;
  if r.status not in ('waiting','running') or r.revoked_at is not null then return jsonb_build_object('allowed',false,'reason','RUN_STOPPED'); end if;
  if t.stage='plan' then return jsonb_build_object('allowed',false,'reason','NO_MODEL_REQUIRED'); end if;
  if exists(select 1 from public.unsite_collection_inputs i join public.unsite_source_versions v on v.id=i.source_version_id join public.unsite_sources s on s.id=v.source_id where i.run_id=r.id and s.archived_at is not null) then return jsonb_build_object('allowed',false,'reason','SOURCE_ARCHIVED'); end if;
  if exists(select 1 from public.unsite_collection_attempts where task_id=t.id and lease_token=p_lease) then return jsonb_build_object('allowed',false,'reason','ALREADY_DISPATCHED'); end if;
  perform pg_advisory_xact_lock(hashtextextended('unsite_ai_daily_budget',0));
  if (select count(*) from public.unsite_collection_attempts where run_id=r.id)>=r.max_requests then return jsonb_build_object('allowed',false,'reason','RUN_REQUEST_LIMIT'); end if;
  if (select count(*) from public.unsite_ai_attempts where started_at>now()-interval '24 hours')+(select count(*) from public.unsite_collection_attempts where started_at>now()-interval '24 hours')>=200
    or (select count(*) from public.unsite_ai_attempts where space_id=r.space_id and started_at>now()-interval '24 hours')+(select count(*) from public.unsite_collection_attempts where space_id=r.space_id and started_at>now()-interval '24 hours')>=50 then return jsonb_build_object('allowed',false,'reason','AI_DAILY_LIMIT'); end if;
  insert into public.unsite_collection_attempts(run_id,space_id,task_id,lease_token,model) values(r.id,r.space_id,t.id,p_lease,p_model) returning id into request_id;
  update public.unsite_collection_tasks set leased_until=now()+interval '150 seconds' where id=t.id;
  return jsonb_build_object('allowed',true,'dispatch_id',request_id);
end $$;
create function public.unsite_collection_finish(p_dispatch_id uuid,p_status text,p_response_id text default null,p_input_tokens integer default null,p_output_tokens integer default null) returns boolean language plpgsql security invoker set search_path='' as $$
begin
  if p_status is null or p_status not in ('succeeded','failed','uncertain') then raise exception 'Invalid attempt status'; end if;
  update public.unsite_collection_attempts set status=p_status,provider_response_id=left(p_response_id,200),input_tokens=p_input_tokens,output_tokens=p_output_tokens,finished_at=now() where id=p_dispatch_id and status in ('in_flight','uncertain');return found;
end $$;

create function unsite_private.valid_collection_item(p jsonb,allowed_segments uuid[]) returns boolean language plpgsql stable security invoker set search_path='' as $$
declare e jsonb;s public.unsite_evidence_segments;f record;l jsonb;
begin
  if jsonb_typeof(p) is distinct from 'object' or jsonb_typeof(p->'title') is distinct from 'string' or jsonb_typeof(p->'text') is distinct from 'string' or coalesce(p->>'kind','') not in ('about','person','offering','project','faq','policy','location','general') or length(btrim(coalesce(p->>'title',''))) not between 1 and 200 or length(btrim(coalesce(p->>'text',''))) not between 1 and 40000 then return false; end if;
  if not unsite_private.valid_knowledge_context(p->'context') or jsonb_typeof(p->'fields') is distinct from 'object' or (select count(*) from jsonb_object_keys(p->'fields'))>30 then return false; end if;
  for f in select * from jsonb_each(p->'fields') loop
    if length(btrim(f.key)) not between 1 and 100 or f.key in ('__proto__','prototype','constructor') or jsonb_typeof(f.value) not in ('string','number','boolean','null') or (jsonb_typeof(f.value)='string' and length(f.value#>>'{}')>4000) then return false; end if;
  end loop;
  if jsonb_typeof(p->'evidence') is distinct from 'array' or jsonb_array_length(p->'evidence') not between 1 and 10 then return false; end if;
  for e in select value from jsonb_array_elements(p->'evidence') loop
    select * into s from public.unsite_evidence_segments where id=(e->>'segment_id')::uuid and id=any(allowed_segments);
    if not found or jsonb_typeof(e->'quote') is distinct from 'string' or s.source_version_id is distinct from (e->>'source_version_id')::uuid or e->>'locator' is distinct from s.locator or length(btrim(regexp_replace(coalesce(e->>'quote',''),'\s+',' ','g'))) not between 12 and 3000 or position(btrim(regexp_replace(e->>'quote','\s+',' ','g')) in btrim(regexp_replace(s.text,'\s+',' ','g')))=0 then return false; end if;
  end loop;
  if jsonb_typeof(p->'warnings') is distinct from 'array' or jsonb_array_length(p->'warnings')>10 or exists(select 1 from jsonb_array_elements(p->'warnings') v where jsonb_typeof(v)<>'string' or length(v#>>'{}')>1000) then return false; end if;
  if jsonb_typeof(p->'suggested_links') is distinct from 'array' or jsonb_array_length(p->'suggested_links')>20 then return false; end if;
  for l in select value from jsonb_array_elements(p->'suggested_links') loop
    if coalesce(l->>'relation','') not in ('related_to','part_of','created_by','depends_on','documents','supersedes') or length(coalesce(l->>'target_title','')) not between 1 and 200 or length(coalesce(l->>'quote','')) not between 12 and 3000 or not exists(select 1 from public.unsite_evidence_segments where id=any(allowed_segments) and position(btrim(regexp_replace(l->>'quote','\s+',' ','g')) in btrim(regexp_replace(text,'\s+',' ','g')))>0) then return false; end if;
  end loop;
  return true;
exception when others then return false;
end $$;
revoke all on function unsite_private.valid_collection_item(jsonb,uuid[]) from public,anon,authenticated;
grant execute on function unsite_private.valid_collection_item(jsonb,uuid[]) to service_role;

create function public.unsite_collection_context(p_task_id uuid,p_lease uuid) returns jsonb language sql stable security invoker set search_path='' as $$
  select jsonb_build_object('run',to_jsonb(r),'segments',coalesce((select jsonb_agg(to_jsonb(e) order by e.ordinal,e.source_version_id) from public.unsite_evidence_segments e join public.unsite_collection_inputs i on i.source_version_id=e.source_version_id where i.run_id=r.id),'[]'::jsonb),
    'extractions',coalesce((select jsonb_agg(jsonb_build_object('id',x.id,'input',x.input,'output',x.output) order by x.ordinal) from public.unsite_collection_tasks x where x.run_id=r.id and x.stage='extract' and x.status='completed'),'[]'::jsonb),
    'curated',(select output from public.unsite_collection_tasks c where c.run_id=r.id and c.id=(t.input->>'curate_task_id')::uuid and c.stage='curate' and c.status='completed'))
  from public.unsite_collection_tasks t join public.unsite_collection_runs r on r.id=t.run_id where t.id=p_task_id and t.status='running' and t.lease_token=p_lease and t.leased_until>now() and r.status='running' and r.revoked_at is null;
$$;

create function public.unsite_collection_result(p_task_id uuid,p_lease uuid,result jsonb) returns boolean language plpgsql security invoker set search_path='' as $$
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

do $$ declare sig text;begin
  foreach sig in array array['unsite_claim_collection_task()','unsite_collection_context(uuid,uuid)','unsite_collection_dispatch(uuid,uuid,text)','unsite_collection_finish(uuid,text,text,integer,integer)','unsite_collection_result(uuid,uuid,jsonb)'] loop
    execute 'revoke all on function public.'||sig||' from public,anon,authenticated';
    execute 'grant execute on function public.'||sig||' to service_role';
  end loop;
end $$;

-- Both preparation paths share one conservative rolling request budget.
create or replace function public.unsite_ai_dispatch(p_job_id uuid,p_lease uuid,p_model text) returns jsonb
language plpgsql security invoker set search_path='' as $$
declare j public.unsite_jobs; a public.unsite_ai_authorizations; request_id uuid;
begin
  -- Match customer command lock order to avoid cancellation/checkpoint deadlocks.
  perform 1 from public.unsite_spaces where id=(select space_id from public.unsite_jobs where id=p_job_id) for key share;
  select * into j from public.unsite_jobs where id=p_job_id for update;
  if not found or j.status<>'running' or j.lease_token is distinct from p_lease or j.leased_until<now() then return jsonb_build_object('allowed',false,'reason','STALE_LEASE'); end if;
  select * into a from public.unsite_ai_authorizations where source_version_id=j.source_version_id and space_id=j.space_id and revoked_at is null;
  if not found then return jsonb_build_object('allowed',false,'reason','AI_APPROVAL_REQUIRED'); end if;
  if exists(select 1 from public.unsite_source_versions v join public.unsite_sources s on s.id=v.source_id where v.id=j.source_version_id and s.archived_at is not null) then return jsonb_build_object('allowed',false,'reason','SOURCE_ARCHIVED'); end if;
  if exists(select 1 from public.unsite_ai_attempts where job_id=j.id and lease_token=p_lease) then return jsonb_build_object('allowed',false,'reason','ALREADY_DISPATCHED'); end if;
  if j.chunk_count<1 or j.cursor>=j.chunk_count then return jsonb_build_object('allowed',false,'reason','NOT_PARSED'); end if;
  perform pg_advisory_xact_lock(hashtextextended('unsite_ai_daily_budget',0));
  -- Conservative development limits; every reserved request counts, including retries.
  if (select count(*) from public.unsite_ai_attempts where started_at>now()-interval '24 hours')+(select count(*) from public.unsite_collection_attempts where started_at>now()-interval '24 hours')>=200
     or (select count(*) from public.unsite_ai_attempts where space_id=j.space_id and started_at>now()-interval '24 hours')+(select count(*) from public.unsite_collection_attempts where space_id=j.space_id and started_at>now()-interval '24 hours')>=50 then
    return jsonb_build_object('allowed',false,'reason','AI_DAILY_LIMIT');
  end if;
  insert into public.unsite_ai_attempts(space_id,job_id,authorization_id,lease_token,chunk_index,model)
    values(j.space_id,j.id,a.id,p_lease,j.cursor,p_model) returning id into request_id;
  update public.unsite_jobs set stage='preparing with AI',leased_until=now()+interval '150 seconds',updated_at=now() where id=j.id;
  return jsonb_build_object('allowed',true,'dispatch_id',request_id,'authorization_id',a.id);
end $$;


-- Collection review uses the existing revision checks, history and publication boundary.
-- Preserve explicit local-variable qualification from the worker-schedule migration.
create or replace function unsite_private.command(action text,p jsonb) returns jsonb
language plpgsql security definer set search_path='' as $$
<<command_state>>
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
    select coalesce(max(version),0)+1 into next_version from public.unsite_source_versions where unsite_source_versions.source_id=command_state.source_id;
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
    update public.unsite_jobs set status='cancelled',stage='cancelled',lease_token=null,leased_until=null,updated_at=now() where space_id=sid and source_version_id in (select id from public.unsite_source_versions where unsite_source_versions.source_id=command_state.source_id) and status not in ('completed','cancelled');
    result := jsonb_build_object('id',source_id);
  elsif action='review_candidate' then
    select * into cand from public.unsite_candidates where id=(p->>'candidate_id')::uuid and space_id=sid for update;
    if not found then raise exception 'Candidate not found'; end if;
    if cand.revision is distinct from (p->>'revision')::integer or cand.status<>'proposed' then raise exception 'Record changed'; end if;
    if p->>'decision' not in ('accept','exclude') or p->>'decision' is null then raise exception 'Invalid decision'; end if;
    if p->>'decision'='accept' then
      if cand.collection_run_id is not null then
        if not exists(select 1 from public.unsite_collection_runs where id=cand.collection_run_id and space_id=sid and status='completed' and revoked_at is null) then raise exception 'Collection run is not ready for review'; end if;
        if coalesce(cand.verification->>'verdict','') not in ('supported','needs_review','unsupported') then raise exception 'Collection verification is incomplete'; end if;
        if (cand.verification->>'verdict'<>'supported' or jsonb_array_length(cand.verification->'issues')>0) and (p->>'verification_reviewed')::boolean is distinct from true then raise exception 'Review the verification concerns'; end if;
      end if;
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

-- Review stays unavailable until all checks in the collection run are checkpointed.
create function public.unsite_collection_overview(p_space_id uuid,p_run_id uuid default null) returns jsonb language sql stable security invoker set search_path='' as $$
select coalesce(jsonb_agg(info order by info->>'created_at' desc),'[]'::jsonb) from (
  select (to_jsonb(r)-'knowledge_snapshot'-'request_id')||jsonb_build_object(
    'phases',(select coalesce(jsonb_agg(to_jsonb(counts)),'[]'::jsonb) from (select stage,count(*) total,count(*) filter(where status='completed') completed,count(*) filter(where status='running') running,count(*) filter(where status='blocked') blocked from public.unsite_collection_tasks where run_id=r.id group by stage) counts),
    'sources',(select coalesce(jsonb_agg(jsonb_build_object('version_id',v.id,'source_id',s.id,'title',s.title,'version',v.version,'archived',s.archived_at is not null,'newer_available',exists(select 1 from public.unsite_source_versions newer where newer.source_id=s.id and newer.version>v.version)) order by s.title),'[]'::jsonb) from public.unsite_collection_inputs i join public.unsite_source_versions v on v.id=i.source_version_id join public.unsite_sources s on s.id=v.source_id where i.run_id=r.id),
    'requests',(select count(*) from public.unsite_collection_attempts where run_id=r.id),
    'input_tokens',(select coalesce(sum(input_tokens),0) from public.unsite_collection_attempts where run_id=r.id),
    'output_tokens',(select coalesce(sum(output_tokens),0) from public.unsite_collection_attempts where run_id=r.id),
    'uncertain_requests',(select count(*) from public.unsite_collection_attempts where run_id=r.id and status='uncertain'),
    'proposals',(select count(*) from public.unsite_candidates where collection_run_id=r.id),
    'unresolved_count',(select coalesce(sum(jsonb_array_length(output->'unresolved')),0) from public.unsite_collection_tasks where run_id=r.id and stage='curate' and status='completed'),
    'empty_passages',(select count(*) from public.unsite_collection_tasks where run_id=r.id and stage='extract' and status='completed' and jsonb_array_length(output->'candidates')=0),
    'notes',case when p_run_id is null then '[]'::jsonb else (select coalesce(jsonb_agg(jsonb_build_object('summary',output->'summary','unresolved',output->'unresolved') order by ordinal),'[]'::jsonb) from public.unsite_collection_tasks where run_id=r.id and stage='curate' and status='completed') end
  ) info
  from (select * from public.unsite_collection_runs where space_id=p_space_id and (p_run_id is null or id=p_run_id) order by created_at desc limit 20) r
) summaries;
$$;
revoke all on function public.unsite_collection_overview(uuid,uuid) from public,anon;
grant execute on function public.unsite_collection_overview(uuid,uuid) to authenticated;

-- Refresh an existing named worker schedule; fresh projects configure Vault first.
do $refresh_schedule$ begin
  if exists(select 1 from cron.job where jobname='unsite-process-sources') then
-- Requires unsite_worker_key, unsite_worker_gateway and unsite_worker_url in Vault.
-- The worker is verified by the Supabase gateway AND a separate scoped credential.
-- No source content is passed through cron or the network request queue.
perform cron.schedule('unsite-process-sources','* * * * *',$job$
  select net.http_post(
    url := (select decrypted_secret from vault.decrypted_secrets where name='unsite_worker_url'),
    headers := jsonb_build_object(
      'Content-Type','application/json',
      'Authorization','Bearer '||(select decrypted_secret from vault.decrypted_secrets where name='unsite_worker_gateway'),
      'X-Unsite-Worker-Key',(select decrypted_secret from vault.decrypted_secrets where name='unsite_worker_key')
    ),
    body := '{}'::jsonb,
    timeout_milliseconds := 5000
  ) where exists (
    select 1 from public.unsite_jobs
    where status='queued' and run_after<=now()
       or status='running' and leased_until<now()
  ) or exists (
    select 1 from public.unsite_collection_runs
    where status in ('waiting','running') and revoked_at is null
  );
$job$);

  end if;
end $refresh_schedule$;
