-- Consent applies to an exact immutable source version, never an entire account.
create table public.unsite_ai_authorizations (
  id uuid primary key default gen_random_uuid(), space_id uuid not null, source_version_id uuid not null,
  provider text not null default 'openai' check(provider='openai'),
  disclosure_version text not null check(disclosure_version='openai-source-preparation-2026-09-05'),
  authorized_by uuid not null references auth.users(id), authorized_at timestamptz not null default now(),
  revoked_by uuid references auth.users(id), revoked_at timestamptz, request_id uuid not null,
  foreign key(space_id,source_version_id) references public.unsite_source_versions(space_id,id) on delete cascade,
  unique(space_id,request_id), unique(space_id,id)
);
create unique index unsite_ai_active_version on public.unsite_ai_authorizations(source_version_id) where revoked_at is null;
create index unsite_ai_authorization_space on public.unsite_ai_authorizations(space_id,source_version_id);
create index unsite_ai_authorized_by on public.unsite_ai_authorizations(authorized_by);
create index unsite_ai_revoked_by on public.unsite_ai_authorizations(revoked_by) where revoked_by is not null;

create table public.unsite_ai_attempts (
  id uuid primary key default gen_random_uuid(), space_id uuid not null references public.unsite_spaces(id) on delete cascade,
  job_id uuid not null, authorization_id uuid not null, lease_token uuid not null, chunk_index integer not null,
  model text not null check(length(model) between 1 and 128),
  status text not null default 'in_flight' check(status in ('in_flight','succeeded','failed','uncertain')),
  provider_response_id text, input_tokens integer check(input_tokens>=0), output_tokens integer check(output_tokens>=0),
  started_at timestamptz not null default now(), finished_at timestamptz,
  foreign key(space_id,job_id) references public.unsite_jobs(space_id,id) on delete cascade,
  foreign key(space_id,authorization_id) references public.unsite_ai_authorizations(space_id,id),
  unique(job_id,lease_token)
);
create index unsite_ai_attempts_budget on public.unsite_ai_attempts(started_at,space_id);
create index unsite_ai_attempts_space on public.unsite_ai_attempts(space_id,started_at desc);
create index unsite_ai_attempts_authorization on public.unsite_ai_attempts(space_id,authorization_id);

alter table public.unsite_ai_authorizations enable row level security;
alter table public.unsite_ai_attempts enable row level security;
revoke all on public.unsite_ai_authorizations,public.unsite_ai_attempts from public,anon,authenticated;
grant all on public.unsite_ai_authorizations,public.unsite_ai_attempts to service_role;
grant select on public.unsite_ai_authorizations,public.unsite_ai_attempts to authenticated;
create policy member_read on public.unsite_ai_authorizations for select to authenticated using (unsite_private.is_member(space_id));
create policy member_read on public.unsite_ai_attempts for select to authenticated using (unsite_private.is_member(space_id));

create function unsite_private.ai_command(action text,p jsonb) returns jsonb
language plpgsql security definer set search_path='' as $$
declare uid uuid:=auth.uid(); sid uuid:=(p->>'space_id')::uuid; vid uuid:=(p->>'version_id')::uuid;
  a public.unsite_ai_authorizations; j public.unsite_jobs;
begin
  if uid is null or not unsite_private.is_member(sid,array['owner','editor']) then raise exception 'Access denied' using errcode='42501'; end if;
  perform 1 from public.unsite_spaces where id=sid for update;
  if not exists(select 1 from public.unsite_source_versions v join public.unsite_sources s on s.id=v.source_id where v.id=vid and v.space_id=sid and s.archived_at is null) then raise exception 'Source not found'; end if;
  select * into j from public.unsite_jobs where source_version_id=vid and space_id=sid for update;
  if not found then raise exception 'Upload is not complete'; end if;
  if action='prepare_source' then
    if coalesce((p->>'approved')::boolean,false) is not true or p->>'disclosure_version' is distinct from 'openai-source-preparation-2026-09-05' then raise exception 'Review the AI disclosure'; end if;
    if p->>'request_id' is null then raise exception 'Request ID required'; end if;
    select * into a from public.unsite_ai_authorizations where space_id=sid and request_id=(p->>'request_id')::uuid;
    if found and (a.revoked_at is not null or a.source_version_id<>vid) then raise exception 'Record changed'; end if;
    if not found then
      select * into a from public.unsite_ai_authorizations where source_version_id=vid and revoked_at is null;
      if not found then
        insert into public.unsite_ai_authorizations(space_id,source_version_id,authorized_by,disclosure_version,request_id)
          values(sid,vid,uid,p->>'disclosure_version',(p->>'request_id')::uuid) returning * into a;
      end if;
    end if;
    if j.status not in ('completed','running','queued') then
      update public.unsite_jobs set status='queued',stage='waiting',attempts=0,run_after=now(),error_code=null,error_message=null,lease_token=null,leased_until=null,updated_at=now() where id=j.id;
    end if;
    insert into public.unsite_events(space_id,actor_id,action,details) values(sid,uid,'ai.authorized',jsonb_build_object('id',vid,'authorization_id',a.id,'provider',a.provider,'disclosure_version',a.disclosure_version));
    return to_jsonb(a);
  elsif action='stop_preparation' then
    update public.unsite_ai_authorizations set revoked_at=now(),revoked_by=uid where source_version_id=vid and revoked_at is null;
    update public.unsite_jobs set status='cancelled',stage='stopped',lease_token=null,leased_until=null,error_code='AI_AUTHORIZATION_REVOKED',error_message='AI preparation was stopped for this source version.',updated_at=now() where id=j.id and status<>'completed';
    insert into public.unsite_events(space_id,actor_id,action,details) values(sid,uid,'ai.stopped',jsonb_build_object('id',vid));
    return jsonb_build_object('id',vid);
  else raise exception 'Unknown command'; end if;
end $$;
revoke all on function unsite_private.ai_command(text,jsonb) from public,anon;
grant execute on function unsite_private.ai_command(text,jsonb) to authenticated;
create function public.unsite_ai_command(action text,payload jsonb) returns jsonb
language sql security invoker set search_path='' as $$ select unsite_private.ai_command(action,payload); $$;
revoke all on function public.unsite_ai_command(text,jsonb) from public,anon;
grant execute on function public.unsite_ai_command(text,jsonb) to authenticated;

-- Reserve a single request immediately before transferring a passage. The row is
-- also the durable boundary between a not-yet-started request and an in-flight one.
create function public.unsite_ai_dispatch(p_job_id uuid,p_lease uuid,p_model text) returns jsonb
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
  if (select count(*) from public.unsite_ai_attempts where started_at>now()-interval '24 hours')>=200
     or (select count(*) from public.unsite_ai_attempts where space_id=j.space_id and started_at>now()-interval '24 hours')>=50 then
    return jsonb_build_object('allowed',false,'reason','AI_DAILY_LIMIT');
  end if;
  insert into public.unsite_ai_attempts(space_id,job_id,authorization_id,lease_token,chunk_index,model)
    values(j.space_id,j.id,a.id,p_lease,j.cursor,p_model) returning id into request_id;
  update public.unsite_jobs set stage='preparing with AI',leased_until=now()+interval '150 seconds',updated_at=now() where id=j.id;
  return jsonb_build_object('allowed',true,'dispatch_id',request_id,'authorization_id',a.id);
end $$;

create function public.unsite_ai_finish(p_dispatch_id uuid,p_status text,p_response_id text default null,p_input_tokens integer default null,p_output_tokens integer default null) returns boolean
language plpgsql security invoker set search_path='' as $$
begin
  if p_status not in ('succeeded','failed','uncertain') then raise exception 'Invalid attempt status'; end if;
  update public.unsite_ai_attempts set status=p_status,finished_at=now(),provider_response_id=left(p_response_id,200),input_tokens=p_input_tokens,output_tokens=p_output_tokens
    where id=p_dispatch_id and status='in_flight';
  return found;
end $$;
revoke all on function public.unsite_ai_dispatch(uuid,uuid,text) from public,anon,authenticated;
revoke all on function public.unsite_ai_finish(uuid,text,text,integer,integer) from public,anon,authenticated;
grant execute on function public.unsite_ai_dispatch(uuid,uuid,text) to service_role;
grant execute on function public.unsite_ai_finish(uuid,text,text,integer,integer) to service_role;

create or replace function public.unsite_claim_job() returns jsonb language plpgsql security invoker set search_path='' as $$
declare j public.unsite_jobs;
begin
  -- An expired provider lease must never silently issue a second paid request.
  update public.unsite_ai_attempts a set status='uncertain',finished_at=now() from public.unsite_jobs j
    where a.job_id=j.id and a.lease_token=j.lease_token and a.status='in_flight' and j.status='running' and j.stage='preparing with AI' and j.leased_until<now();
  update public.unsite_jobs set status='blocked',stage='review needed',error_code='PROVIDER_UNCERTAIN',error_message='The AI request ended without a saved checkpoint. Retry when ready; a repeated request may incur another provider charge.',lease_token=null,leased_until=null,updated_at=now()
    where status='running' and stage='preparing with AI' and leased_until<now();
  update public.unsite_jobs set status='failed',stage='failed',error_code='LEASE_EXHAUSTED',error_message='Processing stopped before completion. Retry to continue from the saved checkpoint.',lease_token=null,leased_until=null,updated_at=now()
    where status='running' and leased_until<now() and attempts>=max_attempts;
  select * into j from public.unsite_jobs where (status='queued' and run_after<=now() or status='running' and leased_until<now()) and attempts<max_attempts order by created_at for update skip locked limit 1;
  if not found then return null; end if;
  update public.unsite_jobs set status='running',stage=case when cursor=0 then 'reading' else 'preparing' end,attempts=attempts+1,lease_token=gen_random_uuid(),leased_until=now()+interval '150 seconds',updated_at=now() where id=j.id returning * into j;
  return to_jsonb(j);
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
      insert into public.unsite_candidates(space_id,source_version_id,job_id,chunk_index,item_index,kind,title,text,fields,evidence,warnings)
        values(j.space_id,j.source_version_id,j.id,j.cursor,n,item->>'kind',item->>'title',item->>'text',item->'fields',item->'evidence',warnings) on conflict do nothing;
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
