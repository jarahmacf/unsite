create extension if not exists vector with schema extensions;

create table public.unsite_semantic_settings(
  space_id uuid primary key references public.unsite_spaces on delete cascade,
  enabled boolean not null default false, daily_query_limit integer not null default 100 check(daily_query_limit between 1 and 1000),
  usage_day date not null default current_date, query_requests integer not null default 0,
  revision integer not null default 1, updated_at timestamptz not null default now()
);
create table public.unsite_embedding_indexes(
  release_id uuid primary key references public.unsite_releases on delete cascade,
  space_id uuid not null references public.unsite_spaces on delete cascade,
  model text not null default 'text-embedding-3-small' check(model='text-embedding-3-small'), dimensions integer not null default 512 check(dimensions=512),
  consent text not null check(consent='openai-public-embeddings-v1'), authorized_by uuid not null, authorized_at timestamptz not null default now(),
  input_characters integer not null, provider_tokens bigint not null default 0
);
create index unsite_embedding_indexes_space on public.unsite_embedding_indexes(space_id);
create table public.unsite_embedding_requests(
  space_id uuid not null references public.unsite_spaces on delete cascade, request_id uuid not null, release_id uuid not null references public.unsite_releases on delete cascade,
  created_at timestamptz not null default now(), primary key(space_id,request_id)
);
create index unsite_embedding_requests_release on public.unsite_embedding_requests(release_id);
create table public.unsite_embedding_chunks(
  id uuid primary key default gen_random_uuid(), space_id uuid not null references public.unsite_spaces on delete cascade,
  release_id uuid not null references public.unsite_embedding_indexes on delete cascade, record_id uuid not null,
  chunk_number integer not null, content text not null check(length(content) between 1 and 2000),
  embedding extensions.vector(512), status text not null default 'queued' check(status in ('queued','running','ready','blocked')),
  lease_token uuid, leased_until timestamptz, error_message text, error_code text, unique(release_id,record_id,chunk_number)
);
create index unsite_embedding_chunks_space on public.unsite_embedding_chunks(space_id,release_id);
create index unsite_embedding_chunks_due on public.unsite_embedding_chunks(release_id,status);
-- The publication is filtered before similarity ranking. Exact cosine search over
-- a bounded, tenant-specific release avoids ANN post-filter recall loss.
do $$ declare t text; begin
  foreach t in array array['unsite_semantic_settings','unsite_embedding_indexes','unsite_embedding_requests','unsite_embedding_chunks'] loop
    execute format('alter table public.%I enable row level security',t);
    execute format('revoke all on public.%I from public,anon,authenticated',t);
    execute format('grant select on public.%I to authenticated',t);
    execute format('grant all on public.%I to service_role',t);
    execute format('create policy member_read on public.%I for select to authenticated using(unsite_private.is_member(space_id))',t);
  end loop;
end $$;

create function unsite_private.semantic_state(sid uuid) returns jsonb language sql stable security invoker set search_path='' as $$
  select jsonb_build_object('settings',coalesce((select to_jsonb(s) from public.unsite_semantic_settings s where space_id=sid),'{"enabled":false,"daily_query_limit":100,"revision":0,"query_requests":0}'),
    'indexes',coalesce((select jsonb_agg(to_jsonb(x) order by authorized_at desc) from (
      select i.*,count(c.id) total_chunks,count(c.id) filter(where c.status='ready') ready_chunks,count(c.id) filter(where c.status='blocked') blocked_chunks,
        count(c.id) filter(where c.status in ('queued','running')) pending_chunks,max(c.error_message) error_message
      from public.unsite_embedding_indexes i left join public.unsite_embedding_chunks c on c.release_id=i.release_id where i.space_id=sid group by i.release_id order by i.authorized_at desc limit 10
    ) x),'[]'));
$$;
revoke all on function unsite_private.semantic_state(uuid) from public,anon;
grant execute on function unsite_private.semantic_state(uuid) to authenticated;

alter function unsite_private.presence_command(text,jsonb) rename to presence_command_before_semantic;
create function unsite_private.presence_command(action text,p jsonb) returns jsonb language plpgsql security definer set search_path='' as $$
declare sid uuid:=(p->>'space_id')::uuid; active_id uuid; result jsonb; settings public.unsite_semantic_settings; chars bigint;
begin
  if action not in ('save_semantic','index_release') then return unsite_private.presence_command_before_semantic(action,p);end if;
  if auth.uid() is null or not unsite_private.is_member(sid,array['owner']) then raise exception 'Owner access required' using errcode='42501';end if;
  select active_release_id into active_id from public.unsite_spaces where id=sid for update;
  if action='save_semantic' then
    select * into settings from public.unsite_semantic_settings where space_id=sid;
    if coalesce(settings.revision,0) is distinct from (p->>'revision')::integer then raise exception 'Record changed';end if;
    if (p->>'enabled')::boolean and p->>'consent' is distinct from 'openai-public-embeddings-v1' then raise exception 'Review the semantic search disclosure';end if;
    insert into public.unsite_semantic_settings(space_id,enabled,daily_query_limit) values(sid,(p->>'enabled')::boolean,(p->>'daily_query_limit')::integer)
      on conflict(space_id) do update set enabled=excluded.enabled,daily_query_limit=excluded.daily_query_limit,revision=unsite_semantic_settings.revision+1,updated_at=now();
    if not (p->>'enabled')::boolean then
      update public.unsite_embedding_chunks set status='blocked',error_message='Semantic search was disabled. Review before restarting.',error_code='disabled',lease_token=null,leased_until=null where space_id=sid and status in ('queued','running');
    end if;
  else
    if active_id is null or active_id is distinct from (p->>'release_id')::uuid then raise exception 'Choose the current public release';end if;
    if p->>'consent' is distinct from 'openai-public-embeddings-v1' then raise exception 'Review the semantic search disclosure';end if;
    if not exists(select 1 from public.unsite_semantic_settings where space_id=sid and enabled) then raise exception 'Enable semantic search first';end if;
    if exists(select 1 from public.unsite_embedding_requests where space_id=sid and request_id=(p->>'request_id')::uuid) then return jsonb_build_object('release_id',active_id);end if;
    if exists(select 1 from public.unsite_embedding_chunks where release_id=active_id and status='running' and leased_until>now()) then raise exception 'The semantic index is already running';end if;
    if exists(select 1 from public.unsite_embedding_chunks where release_id=active_id and status='blocked') and p->>'retry_acknowledged' is distinct from 'true' then raise exception 'Review the retry notice';end if;
    select sum(length(concat_ws(E'\n',data->>'title',data->>'context',data->>'text',data->>'fields'))) into chars from public.unsite_release_records where release_id=active_id;
    if chars is null or chars>2000000 then raise exception 'Semantic indexing supports up to two million public characters per release';end if;
    insert into public.unsite_embedding_requests(space_id,request_id,release_id) values(sid,(p->>'request_id')::uuid,active_id);
    insert into public.unsite_embedding_indexes(release_id,space_id,consent,authorized_by,input_characters) values(active_id,sid,p->>'consent',auth.uid(),chars)
      on conflict(release_id) do update set authorized_at=now(),authorized_by=auth.uid();
    insert into public.unsite_embedding_chunks(space_id,release_id,record_id,chunk_number,content)
      select sid,active_id,r.record_id,(pos-1)/1800,substring(r.body from pos for 2000)
      from (select record_id,concat_ws(E'\n',data->>'title',data->>'context',data->>'text',data->>'fields') body from public.unsite_release_records where release_id=active_id) r
      cross join lateral generate_series(1,length(r.body),1800) pos on conflict(release_id,record_id,chunk_number) do nothing;
    update public.unsite_embedding_chunks set status='queued',error_message=null,error_code=null,lease_token=null,leased_until=null where release_id=active_id and status='blocked';
  end if;
  insert into public.unsite_events(space_id,actor_id,action,details) values(sid,auth.uid(),'semantic.'||action,jsonb_build_object('release_id',active_id,'consent',p->>'consent'));
  return unsite_private.semantic_state(sid);
end $$;
revoke all on function unsite_private.presence_command(text,jsonb) from public,anon;
grant execute on function unsite_private.presence_command(text,jsonb) to authenticated;

alter function unsite_private.presence_state(uuid) rename to presence_state_before_semantic;
create function unsite_private.presence_state(sid uuid) returns jsonb language sql stable security invoker set search_path='' as $$
  select unsite_private.presence_state_before_semantic(sid)||jsonb_build_object('semantic',unsite_private.semantic_state(sid));
$$;
revoke all on function unsite_private.presence_state(uuid) from public,anon;
grant execute on function unsite_private.presence_state(uuid) to authenticated;

create function public.unsite_claim_embeddings() returns jsonb language plpgsql security invoker set search_path='' as $$
declare rid uuid; token uuid:=gen_random_uuid(); payload jsonb;
begin
  update public.unsite_embedding_chunks set status='blocked',error_message='A worker stopped before saving its embedding result. Review before retrying; another charge is possible.',error_code='provider_uncertain',lease_token=null,leased_until=null where status='running' and leased_until<now();
  select c.release_id into rid from public.unsite_embedding_chunks c join public.unsite_spaces sp on sp.active_release_id=c.release_id join public.unsite_semantic_settings s on s.space_id=sp.id and s.enabled
    where c.status='queued' order by c.release_id,c.id for update of c skip locked limit 1;
  if rid is null then return null;end if;
  with selected as (select id from public.unsite_embedding_chunks where release_id=rid and status='queued' order by id for update skip locked limit 16),
    claimed as (update public.unsite_embedding_chunks c set status='running',lease_token=token,leased_until=now()+interval '90 seconds' from selected where c.id=selected.id returning c.id,c.content)
    select jsonb_agg(jsonb_build_object('id',id,'content',content) order by id) into payload from claimed;
  if payload is null then return null;end if;
  return jsonb_build_object('release_id',rid,'lease',token,'chunks',payload);
end $$;
create function public.unsite_embedding_result(p_release uuid,p_lease uuid,p_result jsonb) returns jsonb language plpgsql security invoker set search_path='' as $$
declare item jsonb; c public.unsite_embedding_chunks; n integer; expected integer; sid uuid;
begin
  select space_id into sid from public.unsite_embedding_indexes where release_id=p_release for update;
  if not exists(select 1 from public.unsite_spaces sp join public.unsite_semantic_settings s on s.space_id=sp.id where sp.id=sid and sp.active_release_id=p_release and s.enabled) then return jsonb_build_object('saved',false);end if;
  select count(*) into expected from public.unsite_embedding_chunks where release_id=p_release and lease_token=p_lease and status='running' and leased_until>now();
  if expected=0 then return jsonb_build_object('saved',false);end if;
  if octet_length(p_result::text)>2000000 then raise exception 'Embedding result too large';end if;
  if p_result ? 'error' then
    update public.unsite_embedding_chunks set status='blocked',error_message=left(p_result->>'error',1000),error_code=left(p_result->>'code',100),lease_token=null,leased_until=null where release_id=p_release and lease_token=p_lease and status='running';
  else
    if jsonb_typeof(p_result->'chunks') is distinct from 'array' or jsonb_array_length(p_result->'chunks')<>expected then raise exception 'Incomplete embedding batch';end if;
    for item in select value from jsonb_array_elements(p_result->'chunks') loop
      if jsonb_typeof(item->'embedding') is distinct from 'array' or jsonb_array_length(item->'embedding')<>512 then raise exception 'Invalid embedding dimensions';end if;
      update public.unsite_embedding_chunks set embedding=(item->>'embedding')::extensions.vector(512),status='ready',lease_token=null,leased_until=null,error_message=null,error_code=null
        where id=(item->>'id')::uuid and release_id=p_release and lease_token=p_lease and status='running' and leased_until>now();
      get diagnostics n=row_count;if n<>1 then raise exception 'Embedding lease changed';end if;
    end loop;
    update public.unsite_embedding_indexes set provider_tokens=provider_tokens+greatest(0,coalesce((p_result->>'tokens')::bigint,0)) where release_id=p_release;
  end if;
  return jsonb_build_object('saved',true);
end $$;

create function public.unsite_semantic_available(sid uuid,rid uuid) returns boolean language sql stable security invoker set search_path='' as $$
  select exists(select 1 from public.unsite_spaces sp join public.unsite_semantic_settings s on s.space_id=sp.id and s.enabled join public.unsite_embedding_indexes i on i.release_id=sp.active_release_id
    where sp.id=sid and sp.active_release_id=rid)
    and exists(select 1 from public.unsite_embedding_chunks where release_id=rid and status='ready')
    and not exists(select 1 from public.unsite_embedding_chunks where release_id=rid and status<>'ready');
$$;
create function public.unsite_semantic_query_budget(sid uuid,rid uuid) returns boolean language plpgsql security invoker set search_path='' as $$
begin
  if not public.unsite_semantic_available(sid,rid) then return false;end if;
  update public.unsite_semantic_settings set query_requests=case when usage_day=current_date then query_requests+1 else 1 end,usage_day=current_date
    where space_id=sid and enabled and (usage_day<>current_date or query_requests<daily_query_limit);
  return found;
end $$;
create function public.unsite_hybrid_records(sid uuid,rid uuid,query_text text,query_vector extensions.vector(512),match_count integer default 8,type_filter text default '',kind_filter text default '',topic_filter text default '') returns jsonb language plpgsql stable security invoker set search_path='' as $$
declare q tsquery;
begin
  if not exists(select 1 from public.unsite_spaces where id=sid and active_release_id is not null) then return null;end if;
  if not exists(select 1 from public.unsite_spaces where id=sid and active_release_id=rid) then return jsonb_build_object('changed',true);end if;
  if not public.unsite_semantic_available(sid,rid) then return jsonb_build_object('unavailable',true);end if;
  if length(query_text)>1200 or match_count not between 1 and 20 or query_vector is null then raise exception 'Invalid hybrid query';end if;
  q:=websearch_to_tsquery('english',query_text);
  return (with candidates as materialized (
    select r.* from public.unsite_release_records r where r.release_id=rid and r.space_id=sid
      and (type_filter='' or lower(coalesce(nullif(r.data->'context'->>'type_label',''),case r.data->>'kind' when 'about' then 'Overview' when 'faq' then 'Question & answer' when 'general' then 'Knowledge' else initcap(r.data->>'kind') end))=lower(type_filter))
      and (kind_filter='' or r.data->>'kind'=kind_filter)
      and (topic_filter='' or exists(select 1 from jsonb_array_elements_text(coalesce(r.data->'context'->'topics','[]')) t where lower(t)=lower(topic_filter)))
  ), lexical as (select record_id,row_number() over(order by ts_rank_cd(document,q) desc,record_id) ranking from candidates where document@@q order by ranking limit 100),
  distances as (select c.record_id,min(c.embedding operator(extensions.<=>) query_vector) distance from public.unsite_embedding_chunks c join candidates r on r.record_id=c.record_id where c.release_id=rid and c.status='ready' group by c.record_id),
  semantic as (select record_id,distance,row_number() over(order by distance,record_id) ranking from distances where distance<=0.72 order by ranking limit 100),
  fused as (select coalesce(l.record_id,s.record_id) record_id,coalesce(1.0/(60+l.ranking),0)+coalesce(1.0/(60+s.ranking),0) score,s.distance from lexical l full join semantic s using(record_id)),
  page as (select c.data,f.score,f.distance from fused f join candidates c using(record_id) order by f.score desc,c.record_id limit match_count)
  select jsonb_build_object('records',coalesce(jsonb_agg(data||jsonb_build_object('_retrieval',jsonb_build_object('score',score,'cosine_distance',distance)) order by score desc),'[]'),'total',(select count(*) from fused),'release_id',rid) from page);
end $$;
revoke all on function public.unsite_claim_embeddings(),public.unsite_embedding_result(uuid,uuid,jsonb),public.unsite_semantic_available(uuid,uuid),public.unsite_semantic_query_budget(uuid,uuid),public.unsite_hybrid_records(uuid,uuid,text,extensions.vector,integer,text,text,text) from public,anon,authenticated;
grant execute on function public.unsite_claim_embeddings(),public.unsite_embedding_result(uuid,uuid,jsonb),public.unsite_semantic_available(uuid,uuid),public.unsite_semantic_query_budget(uuid,uuid),public.unsite_hybrid_records(uuid,uuid,text,extensions.vector,integer,text,text,text) to service_role;

alter function public.unsite_public_metadata(uuid) rename to unsite_public_metadata_before_semantic;
create function public.unsite_public_metadata(space_id uuid) returns jsonb language sql stable security invoker set search_path='' as $$
  select case when m is null then null else m||jsonb_build_object('semantic_ready',public.unsite_semantic_available(space_id,(m->>'id')::uuid)) end from (select public.unsite_public_metadata_before_semantic(space_id) m) x;
$$;
revoke all on function public.unsite_public_metadata(uuid) from public,anon,authenticated;
grant execute on function public.unsite_public_metadata(uuid) to service_role;

do $$ declare command_text text;begin
  select command into command_text from cron.job where jobname='unsite-process-sources';
  if command_text is not null then
    command_text:=regexp_replace(command_text,';\s*$','')||' or exists(select 1 from public.unsite_embedding_chunks c join public.unsite_spaces s on s.active_release_id=c.release_id join public.unsite_semantic_settings cfg on cfg.space_id=s.id and cfg.enabled where c.status=''queued'' or (c.status=''running'' and c.leased_until<now()));';
    perform cron.schedule('unsite-process-sources','* * * * *',command_text);
  end if;
end $$;
