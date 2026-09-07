-- Customer data is private by default. Public delivery reads an immutable release.
create schema if not exists unsite_private;
revoke all on schema unsite_private from public, anon;
grant usage on schema unsite_private to authenticated, service_role;

create table public.unsite_spaces (
  id uuid primary key default gen_random_uuid(), owner_id uuid not null references auth.users(id) on delete cascade,
  name text not null check(length(name) between 1 and 200), kind text not null check(kind in ('person','business')),
  description text not null default '' check(length(description)<=5000), contact_email text not null default '' check(length(contact_email)<=200),
  active_release_id uuid, content_revision integer not null default 1, request_id uuid not null,
  created_at timestamptz not null default now(), unique(owner_id,request_id)
);
create table public.unsite_memberships (
  space_id uuid not null references public.unsite_spaces on delete cascade,
  user_id uuid not null references auth.users on delete cascade,
  role text not null check(role in ('owner','editor','viewer')), created_at timestamptz not null default now(), primary key(space_id,user_id)
);
create index unsite_memberships_user on public.unsite_memberships(user_id,space_id);
create table public.unsite_sources (
  id uuid primary key default gen_random_uuid(), space_id uuid not null references public.unsite_spaces on delete cascade,
  title text not null check(length(title) between 1 and 200), kind text not null check(kind in ('file','text','url')),
  origin_url text check(origin_url is null or (origin_url like 'https://%' and length(origin_url)<=2000)),
  created_by uuid not null references auth.users, created_at timestamptz not null default now(), archived_at timestamptz, unique(space_id,id)
);
create index unsite_sources_space on public.unsite_sources(space_id,created_at desc);
create table public.unsite_source_versions (
  id uuid primary key default gen_random_uuid(), space_id uuid not null, source_id uuid not null,
  version integer not null check(version>0), request_id uuid not null,
  storage_path text unique, mime_type text not null check(mime_type in ('text/plain','text/markdown','application/json','application/pdf','text/html')),
  byte_size bigint not null default 0 check(byte_size between 0 and 20971520),
  text_content text check(length(text_content)<=200000), extracted_text text check(length(extracted_text)<=200000),
  content_hash text, created_at timestamptz not null default now(),
  foreign key(space_id,source_id) references public.unsite_sources(space_id,id) on delete cascade,
  unique(source_id,version), unique(space_id,request_id), unique(space_id,id)
);
create index unsite_versions_space on public.unsite_source_versions(space_id,created_at desc);
create table public.unsite_jobs (
  id uuid primary key default gen_random_uuid(), space_id uuid not null, source_version_id uuid not null unique,
  status text not null default 'queued' check(status in ('queued','running','blocked','failed','completed','cancelled')),
  stage text not null default 'waiting', attempts integer not null default 0, max_attempts integer not null default 3,
  progress integer not null default 0 check(progress between 0 and 100), cursor integer not null default 0, chunk_count integer not null default 0,
  lease_token uuid, leased_until timestamptz, error_code text, error_message text,
  run_after timestamptz not null default now(), created_at timestamptz not null default now(), updated_at timestamptz not null default now(),
  foreign key(space_id,source_version_id) references public.unsite_source_versions(space_id,id) on delete cascade,
  unique(space_id,id)
);
create index unsite_jobs_claim on public.unsite_jobs(status,run_after,leased_until) where status in ('queued','running');
create index unsite_jobs_space on public.unsite_jobs(space_id,created_at desc);
create table public.unsite_candidates (
  id uuid primary key default gen_random_uuid(), space_id uuid not null, source_version_id uuid not null, job_id uuid not null,
  chunk_index integer not null, item_index integer not null,
  kind text not null check(kind in ('about','person','offering','project','faq','policy','location','general')),
  title text not null check(length(title) between 1 and 200), text text not null check(length(text) between 1 and 40000),
  fields jsonb not null default '{}' check(jsonb_typeof(fields)='object' and pg_column_size(fields)<=128000),
  evidence jsonb not null check(jsonb_typeof(evidence)='array' and jsonb_array_length(evidence)>0), warnings jsonb not null default '[]' check(jsonb_typeof(warnings)='array'),
  status text not null default 'proposed' check(status in ('proposed','accepted','excluded')), revision integer not null default 1,
  created_at timestamptz not null default now(),
  foreign key(space_id,source_version_id) references public.unsite_source_versions(space_id,id) on delete cascade,
  foreign key(space_id,job_id) references public.unsite_jobs(space_id,id) on delete cascade,
  unique(job_id,chunk_index,item_index), unique(space_id,id)
);
create index unsite_candidates_space on public.unsite_candidates(space_id,status,created_at);
create index unsite_candidates_source on public.unsite_candidates(space_id,source_version_id);
create table public.unsite_records (
  id uuid primary key default gen_random_uuid(), space_id uuid not null references public.unsite_spaces on delete cascade, candidate_id uuid,
  kind text not null check(kind in ('about','person','offering','project','faq','policy','location','general')),
  title text not null check(length(title) between 1 and 200), text text not null check(length(text) between 1 and 40000),
  fields jsonb not null default '{}' check(jsonb_typeof(fields)='object' and pg_column_size(fields)<=128000),
  public_source_url text check(public_source_url is null or (public_source_url like 'https://%' and length(public_source_url)<=2000)),
  revision integer not null default 1, active boolean not null default true, request_id uuid,
  created_by uuid not null references auth.users, updated_at timestamptz not null default now(),
  foreign key(space_id,candidate_id) references public.unsite_candidates(space_id,id), unique(space_id,id), unique(space_id,request_id)
);
create index unsite_records_space on public.unsite_records(space_id,active,updated_at desc);
create index unsite_records_candidate on public.unsite_records(space_id,candidate_id);
create table public.unsite_releases (
  id uuid primary key default gen_random_uuid(), space_id uuid not null references public.unsite_spaces on delete cascade,
  revision integer not null, source_revision integer not null, data jsonb not null, summary text not null default '' check(length(summary)<=500),
  request_id uuid not null, created_by uuid not null references auth.users, published_at timestamptz not null default now(),
  unique(space_id,revision), unique(space_id,request_id), unique(space_id,id)
);
alter table public.unsite_spaces add constraint unsite_active_release foreign key(id,active_release_id) references public.unsite_releases(space_id,id) deferrable initially deferred;
create index unsite_spaces_release on public.unsite_spaces(id,active_release_id);
create table public.unsite_events (
  id uuid primary key default gen_random_uuid(), space_id uuid not null references public.unsite_spaces on delete cascade,
  actor_id uuid references auth.users, action text not null, details jsonb not null default '{}', created_at timestamptz not null default now()
);
create index unsite_events_space on public.unsite_events(space_id,created_at desc);
create table public.unsite_worker_credentials (
  id uuid primary key default gen_random_uuid(), label text not null, token_hash text not null unique,
  active boolean not null default true, created_at timestamptz not null default now()
);

-- This predicate cannot inspect another customer's identity. It breaks RLS recursion.
create function unsite_private.is_member(target uuid, roles text[] default array['owner','editor','viewer']) returns boolean
language sql stable security definer set search_path='' as $$
  select (select auth.uid()) is not null and exists(select 1 from public.unsite_memberships m where m.space_id=target and m.user_id=(select auth.uid()) and m.role=any(roles));
$$;
revoke all on function unsite_private.is_member(uuid,text[]) from public,anon;
grant execute on function unsite_private.is_member(uuid,text[]) to authenticated;

do $$ declare t text; begin
  foreach t in array array['unsite_spaces','unsite_memberships','unsite_sources','unsite_source_versions','unsite_jobs','unsite_candidates','unsite_records','unsite_releases','unsite_events','unsite_worker_credentials'] loop
    execute format('alter table public.%I enable row level security',t);
    execute format('revoke all on public.%I from public,anon,authenticated',t);
    execute format('grant all on public.%I to service_role',t);
    if t <> 'unsite_worker_credentials' then
      execute format('grant select on public.%I to authenticated',t);
      execute format('create policy member_read on public.%I for select to authenticated using (unsite_private.is_member(%I))',t,case when t='unsite_spaces' then 'id' else 'space_id' end);
    end if;
  end loop;
end $$;

insert into storage.buckets(id,name,public,file_size_limit,allowed_mime_types)
values('unsite-sources','unsite-sources',false,20971520,array['application/pdf','text/plain','text/markdown','application/json'])
on conflict(id) do nothing;
create policy unsite_source_read on storage.objects for select to authenticated using (
  bucket_id='unsite-sources' and exists(select 1 from public.unsite_source_versions v where v.storage_path=name and unsite_private.is_member(v.space_id))
);
create policy unsite_source_upload on storage.objects for insert to authenticated with check (
  bucket_id='unsite-sources' and exists(select 1 from public.unsite_source_versions v join public.unsite_sources s on s.id=v.source_id
  where v.storage_path=name and s.archived_at is null and unsite_private.is_member(v.space_id,array['owner','editor']))
);

-- Only narrow, authenticated commands may mutate customer state. This function is
-- in a non-exposed schema; the API wrapper below is SECURITY INVOKER.
create function unsite_private.command(action text,p jsonb) returns jsonb
language plpgsql security definer set search_path='' as $$
declare
  uid uuid := auth.uid(); sid uuid; rid uuid; source_id uuid; version_id uuid; next_version integer;
  sp public.unsite_spaces; cand public.unsite_candidates; job public.unsite_jobs; rec public.unsite_records;
  release public.unsite_releases; v public.unsite_source_versions;
  result jsonb; snapshot jsonb; storage_name text; actual_size bigint;
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
        update public.unsite_records set candidate_id=cand.id,kind=p->>'kind',title=p->>'title',text=p->>'text',fields=p->'fields',public_source_url=nullif(p->>'public_source_url',''),revision=revision+1,active=true,updated_at=now() where id=rec.id returning id into rid;
      else
        insert into public.unsite_records(space_id,candidate_id,kind,title,text,fields,public_source_url,created_by) values(sid,cand.id,p->>'kind',p->>'title',p->>'text',p->'fields',nullif(p->>'public_source_url',''),uid) returning id into rid;
      end if;
      update public.unsite_spaces set content_revision=content_revision+1 where id=sid;
    end if;
    update public.unsite_candidates set status=case when p->>'decision'='accept' then 'accepted' else 'excluded' end,revision=revision+1 where id=cand.id;
    result := jsonb_build_object('id',cand.id,'record_id',rid);
  elsif action in ('create_record','edit_record') then
    if action='edit_record' then
      select * into rec from public.unsite_records where id=(p->>'record_id')::uuid and space_id=sid for update;
      if not found or rec.revision<>(p->>'revision')::integer or p->>'revision' is null then raise exception 'Record changed'; end if;
      update public.unsite_records set kind=p->>'kind',title=p->>'title',text=p->>'text',fields=p->'fields',public_source_url=nullif(p->>'public_source_url',''),active=(p->>'active')::boolean,revision=revision+1,updated_at=now() where id=rec.id returning to_jsonb(unsite_records.*) into result;
    else
      if p->>'request_id' is null then raise exception 'Request ID required'; end if;
      select to_jsonb(r.*) into result from public.unsite_records r where r.space_id=sid and r.request_id=(p->>'request_id')::uuid;
      if found then return result; end if;
      insert into public.unsite_records(space_id,kind,title,text,fields,public_source_url,created_by,request_id) values(sid,p->>'kind',p->>'title',p->>'text',p->'fields',nullif(p->>'public_source_url',''),uid,(p->>'request_id')::uuid) returning to_jsonb(unsite_records.*) into result;
    end if;
    update public.unsite_spaces set content_revision=content_revision+1 where id=sid;
  elsif action='publish_release' then
    if coalesce((p->>'reviewed')::boolean,false) is not true then raise exception 'Review the publication'; end if;
    select * into release from public.unsite_releases where space_id=sid and request_id=(p->>'request_id')::uuid;
    if found then return to_jsonb(release)-'data'; end if;
    if sp.content_revision<>(p->>'revision')::integer or p->>'revision' is null then raise exception 'Record changed'; end if;
    if not exists(select 1 from public.unsite_records where space_id=sid and active) then raise exception 'No approved content'; end if;
    select jsonb_build_object('schema_version','2.0','id',sid,'name',sp.name,'kind',sp.kind,'description',sp.description,'contact_email',nullif(sp.contact_email,''),'records',jsonb_agg(jsonb_strip_nulls(jsonb_build_object('id',r.id,'kind',r.kind,'title',r.title,'text',r.text,'fields',r.fields,'source_url',r.public_source_url,'revision',r.revision)) order by r.kind,r.title,r.id)) into snapshot from public.unsite_records r where r.space_id=sid and r.active;
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
  insert into public.unsite_events(space_id,actor_id,action,details) values(sid,uid,action,jsonb_strip_nulls(jsonb_build_object('id',result->>'id','decision',p->>'decision','record_id',result->>'record_id')));
  return coalesce(result,'{}');
end $$;
revoke all on function unsite_private.command(text,jsonb) from public,anon;
grant execute on function unsite_private.command(text,jsonb) to authenticated;
create function public.unsite_command(action text,payload jsonb) returns jsonb language sql security invoker set search_path='' as $$ select unsite_private.command(action,payload); $$;
revoke all on function public.unsite_command(text,jsonb) from public,anon;
grant execute on function public.unsite_command(text,jsonb) to authenticated;

-- Worker leases fence late results and survive a closed browser or terminated worker.
create function public.unsite_claim_job() returns jsonb language plpgsql security invoker set search_path='' as $$
declare j public.unsite_jobs;
begin
  update public.unsite_jobs set status='failed',stage='failed',error_code='LEASE_EXHAUSTED',error_message='Processing stopped before completion. Retry to continue from the saved checkpoint.',lease_token=null,leased_until=null,updated_at=now()
    where status='running' and leased_until<now() and attempts>=max_attempts;
  select * into j from public.unsite_jobs where (status='queued' and run_after<=now() or status='running' and leased_until<now()) and attempts<max_attempts order by created_at for update skip locked limit 1;
  if not found then return null; end if;
  update public.unsite_jobs set status='running',stage=case when cursor=0 then 'reading' else 'preparing' end,attempts=attempts+1,lease_token=gen_random_uuid(),leased_until=now()+interval '150 seconds',updated_at=now() where id=j.id returning * into j;
  return to_jsonb(j);
end $$;
create function public.unsite_job_result(job_id uuid,lease uuid,result jsonb) returns boolean language plpgsql security invoker set search_path='' as $$
declare j public.unsite_jobs; item jsonb; n integer:=0; warnings jsonb;
begin
  select * into j from public.unsite_jobs where id=job_id for update;
  if not found or j.status<>'running' or j.lease_token is distinct from lease or j.leased_until<now() then return false; end if;
  if result->>'mode'='parsed' then
    update public.unsite_source_versions set extracted_text=result->>'text',content_hash=result->>'hash' where id=j.source_version_id;
    update public.unsite_jobs set chunk_count=(result->>'chunks')::integer,stage='preparing',progress=10,leased_until=now()+interval '150 seconds',updated_at=now() where id=j.id;
  elsif result->>'mode'='chunk' then
    if (result->>'cursor')::integer<>j.cursor then return false; end if;
    for item in select value from jsonb_array_elements(result->'candidates') loop
      warnings := coalesce(item->'warnings','[]');
      if exists(select 1 from public.unsite_records r where r.space_id=j.space_id and r.active and r.kind=item->>'kind' and lower(r.title)=lower(item->>'title'))
        or exists(select 1 from public.unsite_candidates c where c.space_id=j.space_id and c.kind=item->>'kind' and lower(c.title)=lower(item->>'title') and c.status='proposed') then
        warnings := warnings||'"A similar entry exists. Compare it before adding or replacing content."'::jsonb;
      end if;
      insert into public.unsite_candidates(space_id,source_version_id,job_id,chunk_index,item_index,kind,title,text,fields,evidence,warnings)
      values(j.space_id,j.source_version_id,j.id,j.cursor,n,item->>'kind',item->>'title',item->>'text',item->'fields',item->'evidence',warnings) on conflict(job_id,chunk_index,item_index) do nothing;
      n:=n+1;
    end loop;
    update public.unsite_jobs set cursor=cursor+1,status=case when cursor+1>=chunk_count then 'completed' else 'queued' end,
      stage=case when cursor+1>=chunk_count then 'ready for review' else 'preparing' end,
      progress=case when cursor+1>=chunk_count then 100 else least(95,10+(85*(cursor+1)/greatest(chunk_count,1))) end,
      attempts=0,lease_token=null,leased_until=null,run_after=now(),updated_at=now(),error_code=null,error_message=null where id=j.id;
    if j.cursor+1>=j.chunk_count then insert into public.unsite_events(space_id,action,details) values(j.space_id,'source.prepared',jsonb_build_object('id',j.source_version_id)); end if;
  elsif result->>'mode'='error' then
    update public.unsite_jobs set status=case when result->>'disposition'='retry' and attempts<max_attempts then 'queued' when result->>'disposition'='blocked' then 'blocked' else 'failed' end,
      stage=case when result->>'disposition'='blocked' then 'setup needed' else 'interrupted' end,
      error_code=left(result->>'code',100),error_message=left(result->>'message',1000),run_after=now()+make_interval(secs=>least(300,30*attempts)),lease_token=null,leased_until=null,updated_at=now() where id=j.id;
  else raise exception 'Unknown worker result';
  end if;
  return true;
end $$;
revoke all on function public.unsite_claim_job() from public,anon,authenticated;
revoke all on function public.unsite_job_result(uuid,uuid,jsonb) from public,anon,authenticated;
grant execute on function public.unsite_claim_job() to service_role;
grant execute on function public.unsite_job_result(uuid,uuid,jsonb) to service_role;
