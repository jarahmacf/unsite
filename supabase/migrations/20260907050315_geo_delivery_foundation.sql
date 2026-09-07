-- Publisher authority, approved resources, maintenance and measured visibility.
-- Customer writes use guarded commands. Public projections are service-only.
create function unsite_private.public_https(v text) returns boolean language sql immutable set search_path='' as $$
  select v ~ '^https://[A-Za-z0-9][A-Za-z0-9.-]+\.[A-Za-z]{2,}(/[^[:cntrl:]]*)?$'
    and v !~* '^https://(localhost|[^/]+\.(local|internal|localhost))(/|$)' and length(v)<=2000;
$$;

create table public.unsite_publisher_profiles(
  space_id uuid primary key references public.unsite_spaces on delete cascade,
  entity_type text not null default 'Thing' check(entity_type in ('Organization','Person','CreativeWork','Thing')),
  official_url text not null default '' check(official_url='' or unsite_private.public_https(official_url)),
  aliases jsonb not null default '[]' check(jsonb_typeof(aliases)='array' and jsonb_array_length(aliases)<=20),
  profile_urls jsonb not null default '[]' check(jsonb_typeof(profile_urls)='array' and jsonb_array_length(profile_urls)<=12),
  revision integer not null default 1,updated_at timestamptz not null default now()
);
create table public.unsite_domain_claims(
  id uuid primary key default gen_random_uuid(),space_id uuid not null references public.unsite_spaces on delete cascade,
  domain text not null check(domain=lower(domain) and domain ~ '^[a-z0-9]([a-z0-9.-]*[a-z0-9])?\.[a-z]{2,}$' and length(domain)<=253),
  challenge text not null default encode(extensions.gen_random_bytes(32),'hex'),
  status text not null default 'pending' check(status in ('pending','verified','revoked')),
  checked_at timestamptz,verified_at timestamptz,expires_at timestamptz,error_message text,
  next_check_at timestamptz not null default now(),lease_token uuid,leased_until timestamptz,
  request_id uuid not null,created_at timestamptz not null default now(),unique(space_id,request_id),unique(space_id,domain)
);
create index unsite_domain_due on public.unsite_domain_claims(next_check_at) where status<>'revoked';
create table public.unsite_public_resources(
  id uuid primary key,space_id uuid not null references public.unsite_spaces on delete cascade,
  title text not null check(length(btrim(title)) between 1 and 200),description text not null default '' check(length(description)<=2000),
  url text not null check(unsite_private.public_https(url)),mime_type text not null check(mime_type ~ '^[A-Za-z0-9.+_-]+/[A-Za-z0-9.+_-]+$'),
  version_label text not null default '' check(length(version_label)<=100),as_of date,active boolean not null default true,
  revision integer not null default 1,updated_at timestamptz not null default now(),unique(space_id,id)
);
create index unsite_resources_space on public.unsite_public_resources(space_id,active);
create table public.unsite_source_monitors(
  source_id uuid primary key,space_id uuid not null,cadence text not null check(cadence in ('off','daily','weekly')),
  next_check_at timestamptz,last_checked_at timestamptz,last_changed_at timestamptz,failures integer not null default 0,error_message text,
  lease_token uuid,leased_until timestamptz,baseline_version_id uuid,created_at timestamptz not null default now(),
  foreign key(space_id,source_id) references public.unsite_sources(space_id,id) on delete cascade
);
create index unsite_monitors_due on public.unsite_source_monitors(next_check_at) where next_check_at is not null;
create index unsite_monitors_space on public.unsite_source_monitors(space_id);
create table public.unsite_source_changes(
  id uuid primary key default gen_random_uuid(),space_id uuid not null,source_id uuid not null,old_version_id uuid,new_version_id uuid not null,
  affected_record_ids uuid[] not null default '{}',created_at timestamptz not null default now(),
  foreign key(space_id,source_id) references public.unsite_sources(space_id,id) on delete cascade,
  foreign key(space_id,new_version_id) references public.unsite_source_versions(space_id,id),unique(new_version_id)
);
create index unsite_changes_space on public.unsite_source_changes(space_id,created_at desc);
create table public.unsite_visibility_observations(
  id uuid primary key default gen_random_uuid(),space_id uuid not null references public.unsite_spaces on delete cascade,
  question text not null check(length(btrim(question)) between 2 and 1000),platform text not null check(length(btrim(platform)) between 1 and 100),
  mode text not null check(mode in ('web','http','mcp')),observed_at timestamptz not null,
  cited_urls jsonb not null default '[]' check(jsonb_typeof(cited_urls)='array' and jsonb_array_length(cited_urls)<=20),
  preferred_source boolean,correct boolean,notes text not null default '' check(length(notes)<=4000),
  evidence_url text not null default '' check(evidence_url='' or unsite_private.public_https(evidence_url)),
  request_id uuid not null,created_by uuid not null references auth.users,created_at timestamptz not null default now(),unique(space_id,request_id)
);
create index unsite_visibility_space on public.unsite_visibility_observations(space_id,observed_at desc);

do $$ declare t text;begin
  foreach t in array array['unsite_publisher_profiles','unsite_domain_claims','unsite_public_resources','unsite_source_monitors','unsite_source_changes','unsite_visibility_observations'] loop
    execute format('alter table public.%I enable row level security',t);
    execute format('revoke all on public.%I from public,anon,authenticated',t);
    execute format('grant select on public.%I to authenticated',t);
    execute format('grant all on public.%I to service_role',t);
    execute format('create policy member_read on public.%I for select to authenticated using(unsite_private.is_member(space_id))',t);
  end loop;
end $$;

create function unsite_private.presence_command(action text,p jsonb) returns jsonb language plpgsql security definer set search_path='' as $$
declare sid uuid:=(p->>'space_id')::uuid;uid uuid:=auth.uid();sp public.unsite_spaces;result jsonb;profile public.unsite_publisher_profiles;
  claim public.unsite_domain_claims;resource public.unsite_public_resources;item jsonb;source public.unsite_sources;
begin
  if uid is null or not unsite_private.is_member(sid,array['owner','editor']) then raise exception 'Access denied' using errcode='42501';end if;
  if pg_column_size(p)>50000 then raise exception 'Request too large';end if;
  select * into sp from public.unsite_spaces where id=sid for update;
  if action in ('save_publisher','claim_domain','check_domain','revoke_domain','save_resource') and not unsite_private.is_member(sid,array['owner']) then raise exception 'Owner access required' using errcode='42501';end if;
  if action='save_publisher' then
    select * into profile from public.unsite_publisher_profiles where space_id=sid;
    if coalesce(profile.revision,0) is distinct from (p->>'revision')::integer then raise exception 'Record changed';end if;
    if jsonb_typeof(p->'aliases') is distinct from 'array' or jsonb_typeof(p->'profile_urls') is distinct from 'array' then raise exception 'Invalid identity';end if;
    for item in select value from jsonb_array_elements(p->'aliases') loop
      if jsonb_typeof(item)<>'string' or length(btrim(item#>>'{}')) not between 1 and 100 then raise exception 'Invalid alternate name';end if;
    end loop;
    for item in select value from jsonb_array_elements(p->'profile_urls') loop
      if jsonb_typeof(item)<>'string' or not unsite_private.public_https(item#>>'{}') then raise exception 'Invalid profile URL';end if;
    end loop;
    insert into public.unsite_publisher_profiles(space_id,entity_type,official_url,aliases,profile_urls)
      values(sid,p->>'entity_type',p->>'official_url',p->'aliases',p->'profile_urls')
      on conflict(space_id) do update set entity_type=excluded.entity_type,official_url=excluded.official_url,aliases=excluded.aliases,profile_urls=excluded.profile_urls,revision=unsite_publisher_profiles.revision+1,updated_at=now()
      returning to_jsonb(unsite_publisher_profiles.*) into result;
    update public.unsite_spaces set content_revision=content_revision+1 where id=sid;
  elsif action='claim_domain' then
    if (select count(*) from public.unsite_domain_claims where space_id=sid)>=10 and not exists(select 1 from public.unsite_domain_claims where space_id=sid and domain=p->>'domain') then raise exception 'Use up to ten domain claims';end if;
    if not unsite_private.public_https('https://'||(p->>'domain')) then raise exception 'Invalid public domain';end if;
    insert into public.unsite_domain_claims(space_id,domain,request_id) values(sid,p->>'domain',(p->>'request_id')::uuid)
      on conflict(space_id,domain) do update set challenge=encode(extensions.gen_random_bytes(32),'hex'),status='pending',request_id=excluded.request_id,checked_at=null,verified_at=null,expires_at=null,error_message=null,next_check_at=now(),lease_token=null,leased_until=null
      where unsite_domain_claims.status='revoked';
    select to_jsonb(c)-'lease_token'-'leased_until' into result from public.unsite_domain_claims c where c.space_id=sid and c.domain=p->>'domain';
  elsif action in ('check_domain','revoke_domain') then
    select * into claim from public.unsite_domain_claims where id=(p->>'claim_id')::uuid and space_id=sid for update;
    if not found then raise exception 'Domain claim not found';end if;
    if action='revoke_domain' then
      update public.unsite_domain_claims set status='revoked',expires_at=now(),lease_token=null,leased_until=null where id=claim.id;
    else
      if claim.status='revoked' then raise exception 'Add this domain again to create a new proof.';end if;
      if claim.checked_at>now()-interval '1 minute' then raise exception 'Wait one minute before checking again';end if;
      update public.unsite_domain_claims set next_check_at=now() where id=claim.id;
    end if;
    result:=jsonb_build_object('id',claim.id);
  elsif action='save_resource' then
    select * into resource from public.unsite_public_resources where id=(p->>'id')::uuid;
    if found and (resource.space_id<>sid or resource.revision is distinct from (p->>'revision')::integer) then raise exception 'Record changed';end if;
    if not found and (p->>'revision')::integer is distinct from 0 then raise exception 'Resource not found';end if;
    if resource.id is null and (select count(*) from public.unsite_public_resources where space_id=sid)>=200 then raise exception 'Use up to 200 resources';end if;
    insert into public.unsite_public_resources(id,space_id,title,description,url,mime_type,version_label,as_of,active)
      values((p->>'id')::uuid,sid,btrim(p->>'title'),p->>'description',p->>'url',p->>'mime_type',p->>'version_label',(p->>'as_of')::date,(p->>'active')::boolean)
      on conflict(id) do update set title=excluded.title,description=excluded.description,url=excluded.url,mime_type=excluded.mime_type,version_label=excluded.version_label,as_of=excluded.as_of,active=excluded.active,revision=unsite_public_resources.revision+1,updated_at=now()
      returning to_jsonb(unsite_public_resources.*) into result;
    update public.unsite_spaces set content_revision=content_revision+1 where id=sid;
  elsif action in ('save_monitor','check_source') then
    select * into source from public.unsite_sources where id=(p->>'source_id')::uuid and space_id=sid and archived_at is null;
    if not found or source.kind<>'url' then raise exception 'Choose an active web-page source';end if;
    if action='save_monitor' then
      insert into public.unsite_source_monitors(source_id,space_id,cadence,next_check_at) values(source.id,sid,p->>'cadence',case when p->>'cadence'='off' then null else now() end)
      on conflict(source_id) do update set cadence=excluded.cadence,next_check_at=excluded.next_check_at,lease_token=null,leased_until=null;
    else
      if exists(select 1 from public.unsite_source_monitors where source_id=source.id and last_checked_at>now()-interval '5 minutes') then raise exception 'Wait five minutes before checking again';end if;
      insert into public.unsite_source_monitors(source_id,space_id,cadence,next_check_at) values(source.id,sid,'off',now())
      on conflict(source_id) do update set next_check_at=now();
    end if;
    result:=jsonb_build_object('id',source.id);
  elsif action='save_observation' then
    if jsonb_typeof(p->'cited_urls') is distinct from 'array' then raise exception 'Invalid citations';end if;
    for item in select value from jsonb_array_elements(p->'cited_urls') loop
      if jsonb_typeof(item)<>'string' or not unsite_private.public_https(item#>>'{}') then raise exception 'Invalid citation URL';end if;
    end loop;
    if (p->>'observed_at')::timestamptz>now()+interval '5 minutes' then raise exception 'Use the time this observation actually happened';end if;
    insert into public.unsite_visibility_observations(space_id,question,platform,mode,observed_at,cited_urls,preferred_source,correct,notes,evidence_url,request_id,created_by)
      values(sid,p->>'question',p->>'platform',p->>'mode',(p->>'observed_at')::timestamptz,p->'cited_urls',(p->>'preferred_source')::boolean,(p->>'correct')::boolean,p->>'notes',p->>'evidence_url',(p->>'request_id')::uuid,uid)
      on conflict(space_id,request_id) do nothing;
    select jsonb_build_object('id',o.id) into result from public.unsite_visibility_observations o where o.space_id=sid and o.request_id=(p->>'request_id')::uuid;
  elsif action='delete_observation' then
    delete from public.unsite_visibility_observations where id=(p->>'observation_id')::uuid and space_id=sid;
    result:='{}';
  else raise exception 'Unknown presence command';end if;
  insert into public.unsite_events(space_id,actor_id,action,details) values(sid,uid,action,jsonb_build_object('id',result->>'id'));
  return result;
end $$;

create function unsite_private.presence_state(sid uuid) returns jsonb language plpgsql stable security invoker set search_path='' as $$
begin
  if auth.uid() is null or not unsite_private.is_member(sid) then raise exception 'Access denied' using errcode='42501';end if;
  return jsonb_build_object(
    'publisher',coalesce((select to_jsonb(p)-'space_id'-'updated_at' from public.unsite_publisher_profiles p where space_id=sid),'{"entity_type":"Thing","official_url":"","aliases":[],"profile_urls":[],"revision":0}'),
    'claims',(select coalesce(jsonb_agg(to_jsonb(c)-'lease_token'-'leased_until' order by created_at desc),'[]') from public.unsite_domain_claims c where space_id=sid),
    'resources',(select coalesce(jsonb_agg(to_jsonb(r) order by title,id),'[]') from public.unsite_public_resources r where space_id=sid),
    'monitors',(select coalesce(jsonb_agg(to_jsonb(m)-'lease_token'-'leased_until'),'[]') from public.unsite_source_monitors m where space_id=sid),
    'changes',(select coalesce(jsonb_agg(to_jsonb(c) order by created_at desc),'[]') from (select * from public.unsite_source_changes where space_id=sid order by created_at desc limit 100) c),
    'observations',(select coalesce(jsonb_agg(to_jsonb(o) order by observed_at desc),'[]') from (select * from public.unsite_visibility_observations where space_id=sid order by observed_at desc limit 500) o)
  );
end $$;
create function public.unsite_presence_command(action text,payload jsonb) returns jsonb language sql security invoker set search_path='' as $$ select unsite_private.presence_command(action,payload);$$;
create function public.unsite_presence_state(space_id uuid) returns jsonb language sql stable security invoker set search_path='' as $$ select unsite_private.presence_state(space_id);$$;
revoke all on function unsite_private.public_https(text),unsite_private.presence_command(text,jsonb),unsite_private.presence_state(uuid),public.unsite_presence_command(text,jsonb),public.unsite_presence_state(uuid) from public,anon;
grant execute on function unsite_private.public_https(text),unsite_private.presence_command(text,jsonb),unsite_private.presence_state(uuid),public.unsite_presence_command(text,jsonb),public.unsite_presence_state(uuid) to authenticated;
grant execute on function unsite_private.public_https(text) to service_role;

-- Extend the exact projection used by both review and publishing.
alter function unsite_private.knowledge_snapshot(uuid) rename to knowledge_snapshot_before_geo;
create function unsite_private.knowledge_snapshot(target uuid) returns jsonb language sql stable security invoker set search_path='' as $$
  select jsonb_set(base,'{snapshot}',(base->'snapshot')||jsonb_build_object(
    'publisher',coalesce((select to_jsonb(p)-'space_id'-'updated_at' from public.unsite_publisher_profiles p where space_id=target),'{"entity_type":"Thing","official_url":"","aliases":[],"profile_urls":[],"revision":0}'),
    'resources',(select coalesce(jsonb_agg(to_jsonb(r)-'space_id'-'active'-'updated_at' order by r.title,r.id),'[]') from public.unsite_public_resources r where space_id=target and active)
  )) from (select unsite_private.knowledge_snapshot_before_geo(target) base) b where base is not null;
$$;
revoke all on function unsite_private.knowledge_snapshot(uuid) from public,anon;
grant execute on function unsite_private.knowledge_snapshot(uuid) to authenticated;

-- Materialize approved release records once. Never expose this history directly.
create table public.unsite_release_catalog(
  release_id uuid primary key references public.unsite_releases on delete cascade,space_id uuid not null references public.unsite_spaces on delete cascade,
  metadata jsonb not null,record_count integer not null
);
create index unsite_catalog_space on public.unsite_release_catalog(space_id);
create table public.unsite_release_records(
  release_id uuid not null references public.unsite_releases on delete cascade,space_id uuid not null,record_id uuid not null,
  data jsonb not null,document tsvector not null,primary key(release_id,record_id)
);
create index unsite_release_records_search on public.unsite_release_records using gin(document);
create index unsite_release_records_space on public.unsite_release_records(space_id,release_id);
create function unsite_private.index_release() returns trigger language plpgsql security definer set search_path='' as $$
begin
  insert into public.unsite_release_catalog(release_id,space_id,metadata,record_count) values(new.id,new.space_id,new.data-'records',jsonb_array_length(new.data->'records'));
  insert into public.unsite_release_records(release_id,space_id,record_id,data,document)
    select new.id,new.space_id,(r->>'id')::uuid,r,
      setweight(to_tsvector('english',concat_ws(' ',r->>'title',r->'context'->>'summary',r->'context'->>'aliases',r->'context'->>'topics',r->'context'->>'type_label',r->'context'->>'attribution')),'A')||
      setweight(to_tsvector('english',concat_ws(' ',r->>'text',r->>'fields')),'D')
    from jsonb_array_elements(new.data->'records') r;
  return new;
end $$;
revoke all on function unsite_private.index_release() from public,anon,authenticated;
create trigger unsite_index_release after insert on public.unsite_releases for each row execute function unsite_private.index_release();
insert into public.unsite_release_catalog(release_id,space_id,metadata,record_count) select id,space_id,data-'records',jsonb_array_length(data->'records') from public.unsite_releases;
insert into public.unsite_release_records(release_id,space_id,record_id,data,document)
  select rel.id,rel.space_id,(r->>'id')::uuid,r,setweight(to_tsvector('english',concat_ws(' ',r->>'title',r->'context'->>'summary',r->'context'->>'aliases',r->'context'->>'topics',r->'context'->>'type_label',r->'context'->>'attribution')),'A')||setweight(to_tsvector('english',concat_ws(' ',r->>'text',r->>'fields')),'D')
  from public.unsite_releases rel cross join lateral jsonb_array_elements(rel.data->'records') r;
alter table public.unsite_release_catalog enable row level security;
alter table public.unsite_release_records enable row level security;
revoke all on public.unsite_release_catalog,public.unsite_release_records from public,anon,authenticated;
grant all on public.unsite_release_catalog,public.unsite_release_records to service_role;

create function public.unsite_public_directory(page_offset integer default 0,page_limit integer default 100) returns jsonb language sql stable security invoker set search_path='' as $$
  select jsonb_build_object('total',(select count(*) from public.unsite_spaces where active_release_id is not null),'items',coalesce(jsonb_agg(x),'[]'))
  from (select sp.id,c.metadata->>'name' name,c.metadata->>'description' description,rel.id release_id,rel.published_at
    from public.unsite_spaces sp join public.unsite_releases rel on rel.id=sp.active_release_id join public.unsite_release_catalog c on c.release_id=rel.id
    order by sp.id offset greatest(0,page_offset) limit least(100,greatest(1,page_limit))) x;
$$;
create function public.unsite_public_metadata(space_id uuid) returns jsonb language sql stable security invoker set search_path='' as $$
  select jsonb_build_object('id',rel.id,'space_id',rel.space_id,'revision',rel.revision,'source_revision',rel.source_revision,'published_at',rel.published_at,'record_count',c.record_count,'data',c.metadata||jsonb_build_object('records','[]'::jsonb),
    'authority',coalesce((select jsonb_build_object('domain',d.domain,'method','dns_txt','status',case when d.status='verified' and d.expires_at>now() then 'verified' else 'unverified' end,'scope','domain_control','checked_at',d.checked_at,'expires_at',d.expires_at)
      from public.unsite_domain_claims d where d.space_id=sp.id and d.domain=lower(split_part(split_part(c.metadata->'publisher'->>'official_url','://',2),'/',1)) limit 1),'null'::jsonb))
  from public.unsite_spaces sp join public.unsite_releases rel on rel.id=sp.active_release_id join public.unsite_release_catalog c on c.release_id=rel.id where sp.id=$1;
$$;
create function public.unsite_public_records(space_id uuid,p_release uuid,record_id uuid default null,query_text text default '',kind_filter text default '',type_filter text default '',topic_filter text default '',page_offset integer default 0,page_limit integer default 50) returns jsonb language plpgsql stable security invoker set search_path='' as $$
declare active_id uuid;q tsquery;
begin
  select active_release_id into active_id from public.unsite_spaces where id=space_id;
  if active_id is null then return null;end if;
  if active_id<>p_release then return jsonb_build_object('changed',true,'release_id',active_id);end if;
  if length(query_text)>1200 or page_offset<0 or page_limit<1 or page_limit>1000 then raise exception 'Invalid public query';end if;
  q:=websearch_to_tsquery('english',query_text);
  return (with hits as (select r.data,r.record_id,case when btrim(query_text)='' then 0 else ts_rank_cd(r.document,q) end score from public.unsite_release_records r
    where r.release_id=active_id and (unsite_public_records.record_id is null or r.record_id=unsite_public_records.record_id)
      and (btrim(query_text)='' or r.document@@q)
      and (kind_filter='' or r.data->>'kind'=kind_filter)
      and (type_filter='' or lower(coalesce(nullif(r.data->'context'->>'type_label',''),case r.data->>'kind' when 'about' then 'Overview' when 'faq' then 'Question & answer' when 'general' then 'Knowledge' else initcap(r.data->>'kind') end))=lower(type_filter))
      and (topic_filter='' or exists(select 1 from jsonb_array_elements_text(coalesce(r.data->'context'->'topics','[]')) t where lower(t)=lower(topic_filter))))
    select jsonb_build_object('release_id',active_id,'total',(select count(*) from hits),'records',coalesce((select jsonb_agg(page.data order by page.score desc,page.record_id) from (select * from hits order by hits.score desc,hits.record_id offset page_offset limit page_limit) page),'[]')));
end $$;
revoke all on function public.unsite_public_directory(integer,integer),public.unsite_public_metadata(uuid),public.unsite_public_records(uuid,uuid,uuid,text,text,text,text,integer,integer) from public,anon,authenticated;
grant execute on function public.unsite_public_directory(integer,integer),public.unsite_public_metadata(uuid),public.unsite_public_records(uuid,uuid,uuid,text,text,text,text,integer,integer) to service_role;

-- Bounded deterministic maintenance has a separate lease from paid preparation.
create function public.unsite_claim_maintenance() returns jsonb language plpgsql security invoker set search_path='' as $$
declare d public.unsite_domain_claims;m public.unsite_source_monitors;v public.unsite_source_versions;s public.unsite_sources;
begin
  select * into d from public.unsite_domain_claims where status<>'revoked' and next_check_at<=now() and (leased_until is null or leased_until<now()) order by next_check_at for update skip locked limit 1;
  if found then
    update public.unsite_domain_claims set lease_token=gen_random_uuid(),leased_until=now()+interval '90 seconds' where id=d.id returning * into d;
    return jsonb_build_object('kind','domain','id',d.id,'space_id',d.space_id,'domain',d.domain,'challenge',d.challenge,'lease',d.lease_token);
  end if;
  select mon.* into m from public.unsite_source_monitors mon join public.unsite_sources src on src.id=mon.source_id
    where mon.next_check_at<=now() and (mon.leased_until is null or mon.leased_until<now()) and src.archived_at is null
    order by mon.next_check_at for update of mon skip locked limit 1;
  if not found then return null;end if;
  select * into s from public.unsite_sources where id=m.source_id;
  select * into v from public.unsite_source_versions where source_id=s.id and extracted_text is not null order by version desc limit 1;
  update public.unsite_source_monitors set lease_token=gen_random_uuid(),leased_until=now()+interval '150 seconds',baseline_version_id=v.id where source_id=m.source_id returning * into m;
  return jsonb_build_object('kind','source','id',m.source_id,'space_id',m.space_id,'url',s.origin_url,'lease',m.lease_token,'version_id',v.id,'previous_text',v.extracted_text);
end $$;
create function public.unsite_maintenance_result(p_kind text,p_id uuid,p_lease uuid,p_result jsonb) returns jsonb language plpgsql security invoker set search_path='' as $$
declare d public.unsite_domain_claims;m public.unsite_source_monitors;s public.unsite_sources;v public.unsite_source_versions;next_version integer;affected uuid[];changed boolean;
begin
  if p_kind='domain' then
    select * into d from public.unsite_domain_claims where id=p_id for update;
    if not found or d.status='revoked' or d.lease_token is distinct from p_lease or d.leased_until<now() then return jsonb_build_object('saved',false);end if;
    if (p_result->>'verified')::boolean is true then
      update public.unsite_domain_claims set status='verified',checked_at=now(),verified_at=coalesce(verified_at,now()),expires_at=now()+interval '7 days',next_check_at=now()+interval '1 day',error_message=null,lease_token=null,leased_until=null where id=d.id;
    else
      -- An absent proof revokes the public assertion immediately. Network errors
      -- also fail closed until a later check succeeds.
      update public.unsite_domain_claims set status='pending',checked_at=now(),expires_at=now(),next_check_at=now()+interval '1 day',error_message=left(coalesce(p_result->>'error','The required DNS record was not found.'),1000),lease_token=null,leased_until=null where id=d.id;
    end if;
    return jsonb_build_object('saved',true);
  end if;
  if p_kind<>'source' then raise exception 'Invalid maintenance result';end if;
  perform 1 from public.unsite_spaces where id=(select space_id from public.unsite_source_monitors where source_id=p_id) for update;
  select * into m from public.unsite_source_monitors where source_id=p_id for update;
  select * into s from public.unsite_sources where id=p_id;
  if m.source_id is null or s.archived_at is not null or m.lease_token is distinct from p_lease or m.leased_until<now() then return jsonb_build_object('saved',false);end if;
  if p_result ? 'error' then
    update public.unsite_source_monitors set last_checked_at=now(),failures=failures+1,error_message=left(p_result->>'error',1000),lease_token=null,leased_until=null,
      next_check_at=case when cadence='off' then null else now()+make_interval(hours=>least(24,(1<<least(failures,4)))) end where source_id=p_id;
    return jsonb_build_object('saved',true,'changed',false);
  end if;
  if length(btrim(coalesce(p_result->>'text',''))) not between 1 and 200000 then raise exception 'Invalid source text';end if;
  select * into v from public.unsite_source_versions where source_id=p_id and extracted_text is not null order by version desc limit 1;
  -- Compare inside the transaction as well as in the worker. A manual refresh
  -- arriving while the network request ran cannot produce duplicate versions.
  changed:=v.id is null or btrim(regexp_replace(normalize(v.extracted_text,NFKC),'\s+',' ','g')) is distinct from btrim(regexp_replace(normalize(p_result->>'text',NFKC),'\s+',' ','g'));
  if changed and v.id is distinct from m.baseline_version_id then
    update public.unsite_source_monitors set next_check_at=now()+interval '5 minutes',lease_token=null,leased_until=null where source_id=p_id;
    return jsonb_build_object('saved',false,'retry',true);
  end if;
  if changed then
    if (select count(*) from public.unsite_source_versions where space_id=m.space_id)>=500 then
      update public.unsite_source_monitors set cadence='off',next_check_at=null,last_checked_at=now(),error_message='Source version limit reached. Contact support before resuming monitoring.',lease_token=null,leased_until=null where source_id=p_id;
      return jsonb_build_object('saved',true,'changed',false);
    end if;
    select coalesce(array_agg(distinct r.id),'{}') into affected from public.unsite_records r join public.unsite_candidates c on c.id=r.candidate_id
      where r.space_id=m.space_id and r.active and (c.source_version_id in (select id from public.unsite_source_versions where source_id=p_id)
        or exists(select 1 from jsonb_array_elements(c.evidence) e join public.unsite_source_versions sv on sv.id=(e->>'source_version_id')::uuid where sv.source_id=p_id));
    select coalesce(max(version),0)+1 into next_version from public.unsite_source_versions where source_id=p_id;
    insert into public.unsite_source_versions(space_id,source_id,version,request_id,mime_type,byte_size,extracted_text,content_hash)
      values(m.space_id,p_id,next_version,p_lease,'text/html',octet_length(p_result->>'text'),p_result->>'text',encode(extensions.digest(p_result->>'text','sha256'),'hex')) returning * into v;
    insert into public.unsite_jobs(space_id,source_version_id,status,stage,chunk_count,error_code,error_message)
      values(m.space_id,v.id,'blocked','ready to prepare',ceil(length(v.extracted_text)/12000.0),'AI_APPROVAL_REQUIRED','The source changed. Review the new version and approve preparation when ready.');
    insert into public.unsite_source_changes(space_id,source_id,old_version_id,new_version_id,affected_record_ids) values(m.space_id,p_id,m.baseline_version_id,v.id,affected);
    insert into public.unsite_events(space_id,action,details) values(m.space_id,'source.changed',jsonb_build_object('source_id',p_id,'version_id',v.id,'affected_records',cardinality(affected)));
  end if;
  update public.unsite_source_monitors set last_checked_at=now(),last_changed_at=case when changed then now() else last_changed_at end,failures=0,error_message=null,lease_token=null,leased_until=null,
    next_check_at=case cadence when 'daily' then now()+interval '1 day' when 'weekly' then now()+interval '7 days' else null end where source_id=p_id;
  return jsonb_build_object('saved',true,'changed',changed,'version_id',v.id);
end $$;
revoke all on function public.unsite_claim_maintenance(),public.unsite_maintenance_result(text,uuid,uuid,jsonb) from public,anon,authenticated;
grant execute on function public.unsite_claim_maintenance(),public.unsite_maintenance_result(text,uuid,uuid,jsonb) to service_role;

create table public.unsite_public_read_windows(
  space_id uuid not null references public.unsite_spaces on delete cascade,window_start timestamptz not null,count integer not null,
  primary key(space_id,window_start)
);
alter table public.unsite_public_read_windows enable row level security;
revoke all on public.unsite_public_read_windows from public,anon,authenticated;
grant all on public.unsite_public_read_windows to service_role;
create function public.unsite_public_read_budget(space_id uuid) returns boolean language plpgsql security invoker set search_path='' as $$
declare count_now integer;begin
  if not exists(select 1 from public.unsite_spaces s where s.id=space_id and s.active_release_id is not null) then return true;end if;
  insert into public.unsite_public_read_windows(space_id,window_start,count) values(space_id,date_trunc('minute',now()),1)
    on conflict on constraint unsite_public_read_windows_pkey do update set count=unsite_public_read_windows.count+1 returning count into count_now;
  delete from public.unsite_public_read_windows w where w.space_id=unsite_public_read_budget.space_id and w.window_start<now()-interval '1 hour';
  return count_now<=3000;
end $$;
revoke all on function public.unsite_public_read_budget(uuid) from public,anon,authenticated;
grant execute on function public.unsite_public_read_budget(uuid) to service_role;

-- Extend the existing scoped invocation schedule; no provider requests originate
-- in SQL. Existing authentication credentials remain in Vault.
do $$ declare command_text text;begin
  select command into command_text from cron.job where jobname='unsite-process-sources';
  if command_text is not null then
    command_text:=regexp_replace(command_text,';\s*$','')||' or exists(select 1 from public.unsite_domain_claims where status<>''revoked'' and next_check_at<=now()) or exists(select 1 from public.unsite_source_monitors m join public.unsite_sources s on s.id=m.source_id where m.next_check_at<=now() and s.archived_at is null);';
    perform cron.schedule('unsite-process-sources','* * * * *',command_text);
  end if;
end $$;
