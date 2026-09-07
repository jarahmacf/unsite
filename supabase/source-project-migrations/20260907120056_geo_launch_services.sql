create table public.unsite_custom_hosts(
  id uuid primary key default gen_random_uuid(),space_id uuid not null unique references public.unsite_spaces on delete cascade,
  claim_id uuid not null references public.unsite_domain_claims,hostname text not null unique,
  probe_token text not null default encode(extensions.gen_random_bytes(32),'hex'),status text not null default 'pending' check(status in ('pending','active','disabled')),
  checked_at timestamptz,expires_at timestamptz,error_message text,revision integer not null default 1
);
create index unsite_custom_hosts_claim on public.unsite_custom_hosts(claim_id);
create table public.unsite_discovery_settings(
  space_id uuid primary key references public.unsite_spaces on delete cascade,
  google_token text not null default '' check(google_token~'^[a-zA-Z0-9_-]{0,200}$'),bing_token text not null default '' check(bing_token~'^[a-zA-Z0-9_-]{0,200}$'),
  indexnow_enabled boolean not null default false,indexnow_key text not null default encode(extensions.gen_random_bytes(32),'hex'),
  consent text,revision integer not null default 1,updated_at timestamptz not null default now(),
  check(not indexnow_enabled or consent='indexnow-public-urls-v1')
);
create table public.unsite_launch_jobs(
  id uuid primary key default gen_random_uuid(),space_id uuid not null references public.unsite_spaces on delete cascade,
  kind text not null check(kind in ('host','resource','indexnow')),release_id uuid references public.unsite_releases on delete cascade,
  dedupe_key text not null,payload jsonb not null,status text not null default 'queued' check(status in ('queued','running','completed','failed')),
  next_at timestamptz default now(),checked_at timestamptz,lease_token uuid,leased_until timestamptz,
  attempts integer not null default 0,result jsonb,error_message text,created_at timestamptz not null default now(),unique(space_id,kind,dedupe_key)
);
create index unsite_launch_jobs_due on public.unsite_launch_jobs(next_at) where next_at is not null;
create index unsite_launch_jobs_release on public.unsite_launch_jobs(release_id);
do $$ declare t text;begin
  foreach t in array array['unsite_custom_hosts','unsite_discovery_settings','unsite_launch_jobs'] loop
    execute format('alter table public.%I enable row level security',t);
    execute format('revoke all on public.%I from public,anon,authenticated',t);
    execute format('grant select on public.%I to authenticated',t);
    execute format('grant all on public.%I to service_role',t);
    execute format('create policy member_read on public.%I for select to authenticated using(unsite_private.is_member(space_id))',t);
  end loop;
end $$;

create function unsite_private.host_valid(h public.unsite_custom_hosts) returns boolean language sql stable security invoker set search_path='' as $$
  select h.status<>'disabled' and exists(select 1 from public.unsite_domain_claims c where c.id=h.claim_id and c.space_id=h.space_id and c.domain=h.hostname and c.status='verified' and c.expires_at>now());
$$;
create function unsite_private.queue_search_submission(sid uuid,previous_id uuid,current_id uuid,request_key text) returns void language plpgsql security invoker set search_path='' as $$
declare h public.unsite_custom_hosts;d public.unsite_discovery_settings;urls jsonb;
begin
  select * into h from public.unsite_custom_hosts where space_id=sid;
  select * into d from public.unsite_discovery_settings where space_id=sid;
  if h.id is null or h.status<>'active' or h.expires_at<=now() or not unsite_private.host_valid(h) or not coalesce(d.indexnow_enabled,false) then return;end if;
  select jsonb_agg(url order by url) into urls from (
    select 'https://'||h.hostname||'/' as url union
    select 'https://'||h.hostname||'/records/'||record_id from public.unsite_release_records where space_id=sid and release_id in (previous_id,current_id)
  ) u;
  insert into public.unsite_launch_jobs(space_id,kind,release_id,dedupe_key,payload) values(sid,'indexnow',current_id,request_key,
    jsonb_build_object('host_id',h.id,'hostname',h.hostname,'key',d.indexnow_key,'urls',urls)) on conflict(space_id,kind,dedupe_key) do nothing;
end $$;
create function unsite_private.queue_resource_checks(sid uuid,rid uuid) returns void language plpgsql security invoker set search_path='' as $$
begin
  if rid is null then return;end if;
  insert into public.unsite_launch_jobs(space_id,kind,release_id,dedupe_key,payload)
    select sid,'resource',rid,rid::text||'.'||(r->>'id'),jsonb_build_object('resource_id',r->>'id','title',r->>'title','url',r->>'url','mime_type',r->>'mime_type')
    from public.unsite_release_catalog c cross join lateral jsonb_array_elements(coalesce(c.metadata->'resources','[]')) r where c.release_id=rid and c.space_id=sid
    on conflict(space_id,kind,dedupe_key) do update set next_at=now(),status='queued',lease_token=null,leased_until=null,attempts=0;
end $$;
create function unsite_private.queue_launch_release() returns trigger language plpgsql security definer set search_path='' as $$
begin
  if new.active_release_id is distinct from old.active_release_id then
    perform unsite_private.queue_resource_checks(new.id,new.active_release_id);
    perform unsite_private.queue_search_submission(new.id,old.active_release_id,new.active_release_id,gen_random_uuid()::text);
  end if;return new;
end $$;
create trigger unsite_queue_launch_release after update of active_release_id on public.unsite_spaces for each row execute function unsite_private.queue_launch_release();
revoke all on function unsite_private.queue_launch_release(),unsite_private.queue_resource_checks(uuid,uuid),unsite_private.queue_search_submission(uuid,uuid,uuid,text) from public,anon,authenticated;
revoke all on function unsite_private.host_valid(public.unsite_custom_hosts) from public,anon;
grant execute on function unsite_private.host_valid(public.unsite_custom_hosts) to authenticated,service_role;

alter function unsite_private.presence_command(text,jsonb) rename to presence_command_before_launch;
create function unsite_private.presence_command(action text,p jsonb) returns jsonb language plpgsql security definer set search_path='' as $$
declare sid uuid:=(p->>'space_id')::uuid;h public.unsite_custom_hosts;c public.unsite_domain_claims;d public.unsite_discovery_settings;rid uuid;
begin
  if action not in ('register_host','check_host','disable_host','save_discovery','submit_discovery','check_resources') then return unsite_private.presence_command_before_launch(action,p);end if;
  if auth.uid() is null or not unsite_private.is_member(sid,case when action='check_resources' then array['owner','editor'] else array['owner'] end) then raise exception 'Owner access required' using errcode='42501';end if;
  select active_release_id into rid from public.unsite_spaces where id=sid for update;
  select * into h from public.unsite_custom_hosts where space_id=sid;
  select * into d from public.unsite_discovery_settings where space_id=sid;
  if action='register_host' then
    if coalesce(h.revision,0) is distinct from (p->>'revision')::integer then raise exception 'Record changed';end if;
    select * into c from public.unsite_domain_claims where id=(p->>'claim_id')::uuid and space_id=sid and status='verified' and expires_at>now();
    if not found then raise exception 'Verify this exact hostname before connecting it';end if;
    if exists(select 1 from public.unsite_custom_hosts where hostname=c.domain and space_id<>sid) then raise exception 'This hostname is already connected to another workspace';end if;
    insert into public.unsite_custom_hosts(space_id,claim_id,hostname) values(sid,c.id,c.domain)
      on conflict(space_id) do update set claim_id=excluded.claim_id,hostname=excluded.hostname,status='pending',probe_token=encode(extensions.gen_random_bytes(32),'hex'),checked_at=null,expires_at=null,error_message=null,revision=unsite_custom_hosts.revision+1 returning * into h;
    update public.unsite_discovery_settings set indexnow_enabled=false,google_token='',bing_token='',indexnow_key=encode(extensions.gen_random_bytes(32),'hex'),revision=revision+1 where space_id=sid;
  elsif action='disable_host' then
    update public.unsite_custom_hosts set status='disabled',expires_at=now(),revision=revision+1 where space_id=sid;
    update public.unsite_launch_jobs set next_at=null,status='failed',error_message='Custom hostname disabled.',lease_token=null,leased_until=null where space_id=sid and kind in ('host','indexnow');
    update public.unsite_discovery_settings set indexnow_enabled=false,revision=revision+1 where space_id=sid;
  elsif action='check_host' then
    if h.id is null or not unsite_private.host_valid(h) then raise exception 'Verify this exact hostname before connecting it';end if;
    if h.checked_at>now()-interval '1 minute' then raise exception 'Wait one minute before checking again';end if;
  elsif action='check_resources' then
    if rid is null then raise exception 'Choose the current public release';end if;
    if exists(select 1 from public.unsite_events where space_id=sid and action='launch.check_resources' and created_at>now()-interval '5 minutes') then raise exception 'Wait five minutes before checking again';end if;
    perform unsite_private.queue_resource_checks(sid,rid);
  else
    if h.id is null or h.status<>'active' or h.expires_at<=now() or not unsite_private.host_valid(h) then raise exception 'Connect and verify a custom hostname first';end if;
    if action='save_discovery' then
      if coalesce(d.revision,0) is distinct from (p->>'revision')::integer then raise exception 'Record changed';end if;
      if (p->>'indexnow_enabled')::boolean and p->>'consent' is distinct from 'indexnow-public-urls-v1' then raise exception 'Review the search submission disclosure';end if;
      insert into public.unsite_discovery_settings(space_id,google_token,bing_token,indexnow_enabled,consent) values(sid,p->>'google_token',p->>'bing_token',(p->>'indexnow_enabled')::boolean,p->>'consent')
        on conflict(space_id) do update set google_token=excluded.google_token,bing_token=excluded.bing_token,indexnow_enabled=excluded.indexnow_enabled,consent=excluded.consent,revision=unsite_discovery_settings.revision+1,updated_at=now();
      if not (p->>'indexnow_enabled')::boolean then update public.unsite_launch_jobs set next_at=null,status='failed',error_message='Search submissions disabled.',lease_token=null,leased_until=null where space_id=sid and kind='indexnow' and status in ('queued','running');end if;
    else
      if not coalesce(d.indexnow_enabled,false) then raise exception 'Enable search submissions first';end if;
      if exists(select 1 from public.unsite_launch_jobs where space_id=sid and kind='indexnow' and created_at>now()-interval '5 minutes') then raise exception 'Wait five minutes before checking again';end if;
    end if;
    if rid is not null then perform unsite_private.queue_search_submission(sid,null,rid,gen_random_uuid()::text);end if;
  end if;
  if action in ('register_host','check_host') then
    insert into public.unsite_launch_jobs(space_id,kind,dedupe_key,payload) values(sid,'host',h.id::text,jsonb_build_object('host_id',h.id,'hostname',h.hostname,'probe_token',h.probe_token))
      on conflict(space_id,kind,dedupe_key) do update set payload=excluded.payload,status='queued',next_at=now(),lease_token=null,leased_until=null,attempts=0;
  end if;
  insert into public.unsite_events(space_id,actor_id,action,details) values(sid,auth.uid(),'launch.'||action,jsonb_build_object('host_id',h.id));
  return jsonb_build_object('saved',true);
end $$;
revoke all on function unsite_private.presence_command(text,jsonb) from public,anon;
grant execute on function unsite_private.presence_command(text,jsonb) to authenticated;

alter function unsite_private.presence_state(uuid) rename to presence_state_before_launch;
create function unsite_private.presence_state(sid uuid) returns jsonb language sql stable security invoker set search_path='' as $$
  select unsite_private.presence_state_before_launch(sid)||jsonb_build_object(
    'hosting',(select to_jsonb(h)-'probe_token'||jsonb_build_object('proof_valid',unsite_private.host_valid(h)) from public.unsite_custom_hosts h where space_id=sid),
    'discovery',coalesce((select to_jsonb(d)-'indexnow_key' from public.unsite_discovery_settings d where space_id=sid),'{"google_token":"","bing_token":"","indexnow_enabled":false,"revision":0}'),
    'resource_checks',coalesce((select jsonb_agg(x order by checked_at desc nulls first) from (
      select j.id,j.release_id,j.status,j.checked_at,j.next_at,j.result,j.error_message,j.payload->>'resource_id' resource_id,j.payload->>'url' url,j.payload->>'title' title from public.unsite_launch_jobs j join public.unsite_spaces sp on sp.active_release_id=j.release_id where j.space_id=sid and j.kind='resource'
    ) x),'[]'),
    'submissions',coalesce((select jsonb_agg(x order by created_at desc) from (select id,release_id,status,created_at,checked_at,next_at,result,error_message from public.unsite_launch_jobs where space_id=sid and kind='indexnow' order by created_at desc limit 20) x),'[]'));
$$;
revoke all on function unsite_private.presence_state(uuid) from public,anon;
grant execute on function unsite_private.presence_state(uuid) to authenticated;

create function public.unsite_public_host(hostname text) returns jsonb language sql stable security invoker set search_path='' as $$
  select jsonb_build_object('space_id',h.space_id,'hostname',h.hostname,'probe_token',h.probe_token,'routable',h.status='active' and h.expires_at>now(),
    'published',sp.active_release_id is not null,'release_id',sp.active_release_id,'indexnow_key',case when d.indexnow_enabled and h.status='active' and h.expires_at>now() then d.indexnow_key else null end)
    from public.unsite_custom_hosts h join public.unsite_spaces sp on sp.id=h.space_id left join public.unsite_discovery_settings d on d.space_id=h.space_id
    where h.hostname=unsite_public_host.hostname and unsite_private.host_valid(h);
$$;
alter function public.unsite_public_metadata(uuid) rename to unsite_public_metadata_before_launch;
create function public.unsite_public_metadata(space_id uuid) returns jsonb language sql stable security invoker set search_path='' as $$
  select case when m is null then null else m||jsonb_build_object('canonical_origin',case when h.status='active' and h.expires_at>now() and unsite_private.host_valid(h) then 'https://'||h.hostname else null end,
    'discovery',case when h.status='active' and h.expires_at>now() and unsite_private.host_valid(h) then jsonb_build_object('google_token',d.google_token,'bing_token',d.bing_token) else null end) end
    from (select public.unsite_public_metadata_before_launch(space_id) m) x left join public.unsite_custom_hosts h on h.space_id=unsite_public_metadata.space_id left join public.unsite_discovery_settings d on d.space_id=h.space_id;
$$;
revoke all on function public.unsite_public_host(text),public.unsite_public_metadata(uuid) from public,anon,authenticated;
grant execute on function public.unsite_public_host(text),public.unsite_public_metadata(uuid) to service_role;

create function public.unsite_claim_launch_job() returns jsonb language plpgsql security invoker set search_path='' as $$
declare j public.unsite_launch_jobs;h public.unsite_custom_hosts;
begin
  for j in select * from public.unsite_launch_jobs where next_at<=now() and (status<>'running' or leased_until<now()) order by next_at,created_at for update skip locked limit 10 loop
    select * into h from public.unsite_custom_hosts where space_id=j.space_id;
    if (j.kind='resource' and not exists(select 1 from public.unsite_spaces where id=j.space_id and active_release_id=j.release_id))
      or (j.kind in ('host','indexnow') and (h.id is null or h.id::text is distinct from j.payload->>'host_id' or h.hostname is distinct from j.payload->>'hostname' or not unsite_private.host_valid(h)))
      or (j.kind='indexnow' and (h.status<>'active' or h.expires_at<=now() or not exists(select 1 from public.unsite_discovery_settings where space_id=j.space_id and indexnow_enabled and indexnow_key=j.payload->>'key'))) then
      update public.unsite_launch_jobs set status='failed',next_at=null,error_message='Publication, hostname, or authorization changed.',lease_token=null,leased_until=null where id=j.id;continue;
    end if;
    update public.unsite_launch_jobs set status='running',lease_token=gen_random_uuid(),leased_until=now()+interval '180 seconds',attempts=attempts+1 where id=j.id returning * into j;
    return jsonb_build_object('id',j.id,'kind',j.kind,'space_id',j.space_id,'release_id',j.release_id,'lease',j.lease_token,'payload',j.payload);
  end loop;
  return null;
end $$;
create function public.unsite_launch_result(p_id uuid,p_lease uuid,p_result jsonb) returns jsonb language plpgsql security invoker set search_path='' as $$
declare j public.unsite_launch_jobs;h public.unsite_custom_hosts;ok boolean;retry_at timestamptz;
begin
  select * into j from public.unsite_launch_jobs where id=p_id for update;
  if not found or j.status<>'running' or j.lease_token is distinct from p_lease or j.leased_until<now() then return jsonb_build_object('saved',false);end if;
  if octet_length(p_result::text)>16000 then raise exception 'Check result too large';end if;
  if j.kind='resource' and not exists(select 1 from public.unsite_spaces where id=j.space_id and active_release_id=j.release_id) then return jsonb_build_object('saved',false);end if;
  select * into h from public.unsite_custom_hosts where space_id=j.space_id for update;
  if j.kind in ('host','indexnow') and (h.id::text is distinct from j.payload->>'host_id' or h.hostname is distinct from j.payload->>'hostname' or not unsite_private.host_valid(h)) then return jsonb_build_object('saved',false);end if;
  if j.kind='indexnow' and not exists(select 1 from public.unsite_discovery_settings where space_id=j.space_id and indexnow_enabled and indexnow_key=j.payload->>'key') then return jsonb_build_object('saved',false);end if;
  ok:=coalesce((p_result->>'ok')::boolean,false);
  if j.kind='host' then
    if h.probe_token is distinct from j.payload->>'probe_token' then return jsonb_build_object('saved',false);end if;
    update public.unsite_custom_hosts set status=case when ok then 'active' else 'pending' end,checked_at=now(),expires_at=case when ok then now()+interval '7 days' else null end,error_message=case when ok then null else coalesce(left(p_result->>'error',1000),'The hostname did not return this workspace connection proof.') end where id=h.id;
    retry_at:=now()+case when ok then interval '1 day' else interval '1 hour' end;
  elsif j.kind='resource' then retry_at:=now()+interval '1 day';
  elsif not ok and j.attempts<4 and coalesce((p_result->>'retryable')::boolean,false) then retry_at:=now()+make_interval(secs=>least(86400,greatest(300,coalesce((p_result->>'retry_after')::integer,3600))));end if;
  update public.unsite_launch_jobs set status=case when ok then 'completed' else 'failed' end,checked_at=now(),result=p_result,error_message=left(p_result->>'error',1000),next_at=retry_at,lease_token=null,leased_until=null where id=j.id;
  return jsonb_build_object('saved',true);
end $$;
revoke all on function public.unsite_claim_launch_job(),public.unsite_launch_result(uuid,uuid,jsonb) from public,anon,authenticated;
grant execute on function public.unsite_claim_launch_job(),public.unsite_launch_result(uuid,uuid,jsonb) to service_role;

do $$ declare command_text text;begin
  select command into command_text from cron.job where jobname='unsite-process-sources';
  if command_text is not null then
    command_text:=regexp_replace(command_text,';\s*$','')||' or exists(select 1 from public.unsite_launch_jobs where next_at<=now() and (status<>''running'' or leased_until<now()));';
    perform cron.schedule('unsite-process-sources','* * * * *',command_text);
  end if;
end $$;
