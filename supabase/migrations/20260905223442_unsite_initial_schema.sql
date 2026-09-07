-- Initial schema only. Existing deployments must apply pending migrations separately.
do $$ begin if to_regclass('public.unsite_spaces') is not null or to_regclass('public.unsite_publications') is not null then raise exception 'This bootstrap requires an empty Unsite database'; end if; end $$;

-- Source: supabase/migrations/20260905013717_unsite_publications.sql
-- Hosted migration: unsite_publications. All direct client access is denied.
-- The Edge Function authenticates the private portal's scoped publisher key.
create table public.unsite_publishers (
  id uuid primary key default gen_random_uuid(),
  label text not null,
  token_hash text not null unique check (token_hash ~ '^[0-9a-f]{64}$'),
  active boolean not null default true,
  created_at timestamptz not null default now()
);
create table public.unsite_publications (
  id uuid primary key,
  publisher_id uuid not null references public.unsite_publishers(id),
  owner_key text not null check (owner_key ~ '^[0-9a-f]{64}$'),
  data jsonb,
  active boolean not null default false,
  revision integer not null check (revision > 0),
  source_revision integer not null check (source_revision > 0),
  published_at timestamptz not null default now(),
  check (not active or (data is not null and jsonb_typeof(data) = 'object')),
  check (data is null or octet_length(data::text) <= 1000000)
);
create index unsite_publications_publisher_idx on public.unsite_publications (publisher_id);
alter table public.unsite_publishers enable row level security;
alter table public.unsite_publications enable row level security;
revoke all on public.unsite_publishers, public.unsite_publications from public, anon, authenticated;
grant select on public.unsite_publishers to service_role;
grant select, insert, update on public.unsite_publications to service_role;
create policy "Publisher backend only" on public.unsite_publishers for select to service_role using (true);
create policy "Publication backend only" on public.unsite_publications for all to service_role using (true) with check (true);

create function public.unsite_publish(
  p_id uuid, p_publisher uuid, p_owner text, p_source_revision integer,
  p_expected_revision integer, p_active boolean, p_data jsonb
) returns jsonb language plpgsql security invoker set search_path = '' as $$
declare
  existing public.unsite_publications%rowtype;
  result public.unsite_publications%rowtype;
begin
  if p_owner is null or p_owner !~ '^[0-9a-f]{64}$' or p_source_revision is null or p_source_revision < 1
    or p_expected_revision is null or p_expected_revision < 0 or p_active is null
    or (p_active and (p_data is null or jsonb_typeof(p_data) <> 'object')) then
    raise exception 'Invalid publication request';
  end if;
  if not exists (select 1 from public.unsite_publishers where id=p_publisher and active) then
    raise exception 'Publisher not available';
  end if;
  -- Serialize first publication and updates, including retries after a lost response.
  perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended(p_id::text, 0));
  select * into existing from public.unsite_publications where id=p_id for update;
  if found then
    if existing.publisher_id <> p_publisher or existing.owner_key <> p_owner then
      raise exception 'Publication ownership mismatch';
    end if;
    if existing.source_revision=p_source_revision and existing.active=p_active
      and existing.data is not distinct from (case when p_active then p_data else null end) then
      return jsonb_build_object('revision',existing.revision,'published_at',existing.published_at);
    end if;
    if existing.revision <> p_expected_revision or p_source_revision < existing.source_revision then
      raise exception 'Publication revision mismatch';
    end if;
    update public.unsite_publications set data=case when p_active then p_data else null end,
      active=p_active, revision=revision+1,source_revision=p_source_revision,published_at=now()
      where id=p_id returning * into result;
  else
    if p_expected_revision <> 0 or not p_active then raise exception 'Publication revision mismatch'; end if;
    insert into public.unsite_publications (id,publisher_id,owner_key,data,active,revision,source_revision)
      values (p_id,p_publisher,p_owner,p_data,true,1,p_source_revision) returning * into result;
  end if;
  return jsonb_build_object('revision',result.revision,'published_at',result.published_at);
end;
$$;
revoke all on function public.unsite_publish(uuid,uuid,text,integer,integer,boolean,jsonb) from public,anon,authenticated;
grant execute on function public.unsite_publish(uuid,uuid,text,integer,integer,boolean,jsonb) to service_role;


-- Source: supabase/migrations/20260905025957_unsite_production_foundation.sql
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


-- Source: supabase/migrations/20260905030809_unsite_worker_schedule.sql
-- Qualify local source variables explicitly to avoid ambiguous SQL names.
create or replace function unsite_private.command(action text,p jsonb) returns jsonb
language plpgsql security definer set search_path='' as $$
<<command_state>>
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

create extension if not exists pg_cron;
create extension if not exists pg_net;
create extension if not exists supabase_vault;


-- Source: supabase/migrations/20260905031347_unsite_worker_checkpoint.sql
-- Avoid the job_id parameter shadowing the unique conflict target.
create or replace function public.unsite_job_result(job_id uuid,lease uuid,result jsonb) returns boolean language plpgsql security invoker set search_path='' as $$
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
      stage=case when result->>'disposition'='blocked' then 'setup needed' else 'interrupted' end,
      error_code=left(result->>'code',100),error_message=left(result->>'message',1000),run_after=now()+make_interval(secs=>least(300,30*attempts)),lease_token=null,leased_until=null,updated_at=now() where id=j.id;
  else raise exception 'Unknown worker result';
  end if;
  return true;
end $$;


-- Source: supabase/migrations/20260905033810_unsite_network_extension_namespace.sql
-- The newly enabled, non-relocatable extension used the public namespace.
-- Reinstall it with a supported namespace while this development queue is empty.
-- No CASCADE: any unexpected dependency aborts this migration.
do $$ begin
  if exists(select 1 from public.unsite_jobs) or exists(select 1 from public.unsite_source_versions) or exists(select 1 from net.http_request_queue) then
    raise exception 'Queue is not empty; schedule a maintenance migration instead';
  end if;
end $$;
drop extension pg_net;
create extension pg_net with schema extensions;


-- Source: supabase/migrations/20260905043535_unsite_ai_authorization.sql
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


-- Source: supabase/migrations/20260905044327_unsite_ai_attempt_recovery.sql
-- Preserve ambiguous outcomes for stopped or expired requests.
create or replace function public.unsite_claim_job() returns jsonb language plpgsql security invoker set search_path='' as $$
declare j public.unsite_jobs;
begin
  -- An expired provider lease must never silently issue a second paid request.
  update public.unsite_ai_attempts a set status='uncertain',finished_at=now() from public.unsite_jobs active_job
    where a.job_id=active_job.id and a.status='in_flight' and (active_job.status<>'running' or active_job.lease_token is distinct from a.lease_token or active_job.leased_until<now());
  update public.unsite_jobs set status='blocked',stage='review needed',error_code='PROVIDER_UNCERTAIN',error_message='The AI request ended without a saved checkpoint. Retry when ready; a repeated request may incur another provider charge.',lease_token=null,leased_until=null,updated_at=now()
    where status='running' and stage='preparing with AI' and leased_until<now();
  update public.unsite_jobs set status='failed',stage='failed',error_code='LEASE_EXHAUSTED',error_message='Processing stopped before completion. Retry to continue from the saved checkpoint.',lease_token=null,leased_until=null,updated_at=now()
    where status='running' and leased_until<now() and attempts>=max_attempts;
  select * into j from public.unsite_jobs where (status='queued' and run_after<=now() or status='running' and leased_until<now()) and attempts<max_attempts order by created_at for update skip locked limit 1;
  if not found then return null; end if;
  update public.unsite_jobs set status='running',stage=case when cursor=0 then 'reading' else 'preparing' end,attempts=attempts+1,lease_token=gen_random_uuid(),leased_until=now()+interval '150 seconds',updated_at=now() where id=j.id returning * into j;
  return to_jsonb(j);
end $$;

create or replace function public.unsite_ai_finish(p_dispatch_id uuid,p_status text,p_response_id text default null,p_input_tokens integer default null,p_output_tokens integer default null) returns boolean
language plpgsql security invoker set search_path='' as $$
begin
  if p_status is null or p_status not in ('succeeded','failed','uncertain') then raise exception 'Invalid attempt status'; end if;
  update public.unsite_ai_attempts set status=p_status,finished_at=now(),provider_response_id=left(p_response_id,200),input_tokens=p_input_tokens,output_tokens=p_output_tokens
    where id=p_dispatch_id and status in ('in_flight','uncertain');
  return found;
end $$;


-- Source: supabase/migrations/20260905183037_unsite_linked_knowledge.sql
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


-- Source: supabase/migrations/20260905185711_unsite_linked_command_scope.sql
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


-- Source: supabase/migrations/20260905185808_unsite_context_validator_scope.sql
create or replace function unsite_private.valid_knowledge_context(c jsonb) returns boolean
language plpgsql immutable security invoker set search_path='' as $$
declare x jsonb; k text;
begin
  if c is null or jsonb_typeof(c)<>'object' or pg_column_size(c)>12000 then return false; end if;
  if exists(select 1 from jsonb_object_keys(c) as context_keys(name) where context_keys.name not in ('summary','aliases','topics','status','as_of')) then return false; end if;
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


-- Source: supabase/migrations/20260905205859_unsite_universal_context.sql
-- Optional domain-independent metadata; existing contexts and releases remain valid.
create or replace function unsite_private.valid_knowledge_context(c jsonb) returns boolean
language plpgsql immutable security invoker set search_path='' as $$
declare x jsonb; k text;
begin
  if c is null or jsonb_typeof(c)<>'object' or pg_column_size(c)>12000 then return false; end if;
  if exists(select 1 from jsonb_object_keys(c) as context_keys(name) where context_keys.name not in ('summary','aliases','topics','status','as_of','type_label','framing','attribution')) then return false; end if;
  if jsonb_typeof(c->'summary') is distinct from 'string' or length(c->>'summary')>1200 or coalesce(c->>'status','') not in ('unspecified','current','historical','uncertain') then return false; end if;
  if c ? 'type_label' and (jsonb_typeof(c->'type_label') is distinct from 'string' or length(c->>'type_label')>100) then return false; end if;
  if c ? 'attribution' and (jsonb_typeof(c->'attribution') is distinct from 'string' or length(c->>'attribution')>600) then return false; end if;
  if c ? 'framing' and coalesce(c->>'framing','') not in ('unspecified','source_claim','opinion','fiction','instruction','interpretation','mixed') then return false; end if;
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


-- Source: supabase/pending/collection-coordination.sql
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
    select coalesce(array_agg(value),'{}') into covered from jsonb_array_elements(o->'batches') b cross join lateral jsonb_array_elements_text(b->'source_items');
    if cardinality(expected)>1000 or cardinality(expected)<>cardinality(covered) or not(expected<@covered and covered<@expected) then raise exception 'Collection plan must cover every source item once'; end if;
    for batch in select value from jsonb_array_elements(o->'batches') loop
      if jsonb_array_length(batch->'source_items') not between 1 and 20 or jsonb_typeof(batch->'record_ids') is distinct from 'array' or jsonb_array_length(batch->'record_ids')>4 then raise exception 'Invalid collection batch'; end if;
      if exists(select 1 from jsonb_array_elements_text(batch->'record_ids') id where not exists(select 1 from jsonb_array_elements(r.knowledge_snapshot->'records') rec where rec->>'id'=id)) then raise exception 'Invalid existing knowledge reference'; end if;
      insert into public.unsite_collection_tasks(run_id,space_id,stage,ordinal,input) values(r.id,r.space_id,'curate',n,batch);n:=n+1;
    end loop;
  elsif t.stage='curate' then
    if jsonb_typeof(o->'proposals') is distinct from 'array' or jsonb_array_length(o->'proposals')>40 or jsonb_typeof(o->'unresolved') is distinct from 'array' or jsonb_array_length(o->'unresolved')>20 or length(coalesce(o->>'summary',''))>2000 then raise exception 'Invalid curation'; end if;
    select array_agg(value) into expected from jsonb_array_elements_text(t.input->'source_items');
    select coalesce(array_agg(id),'{}') into covered from (select value id from jsonb_array_elements(o->'proposals') p cross join lateral jsonb_array_elements_text(p->'source_items') union all select unresolved.value->>'source_item_id' from jsonb_array_elements(o->'unresolved') unresolved(value)) ids;
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
