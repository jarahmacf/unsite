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
