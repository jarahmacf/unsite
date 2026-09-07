alter table public.unsite_visibility_observations add column stale_answer boolean;
create table public.unsite_delivery_checks(
  id uuid primary key default gen_random_uuid(),space_id uuid not null references public.unsite_spaces on delete cascade,
  release_id uuid not null references public.unsite_releases,status text not null default 'queued' check(status in ('queued','running','completed','failed')),
  lease_token uuid,leased_until timestamptz,result jsonb,error_message text,created_at timestamptz not null default now(),request_id uuid not null,unique(space_id,request_id)
);
create index unsite_delivery_checks_space on public.unsite_delivery_checks(space_id,created_at desc);
create index unsite_delivery_checks_release on public.unsite_delivery_checks(release_id);
create index unsite_delivery_checks_due on public.unsite_delivery_checks(created_at) where status in ('queued','running');
alter table public.unsite_delivery_checks enable row level security;
revoke all on public.unsite_delivery_checks from public,anon,authenticated;
grant select on public.unsite_delivery_checks to authenticated;
grant all on public.unsite_delivery_checks to service_role;
create policy member_read on public.unsite_delivery_checks for select to authenticated using(unsite_private.is_member(space_id));

alter function unsite_private.presence_command(text,jsonb) rename to presence_command_before_checks;
create function unsite_private.presence_command(action text,p jsonb) returns jsonb language plpgsql security definer set search_path='' as $$
declare sid uuid:=(p->>'space_id')::uuid;result jsonb;active_id uuid;
begin
  if auth.uid() is null or not unsite_private.is_member(sid,array['owner','editor']) then raise exception 'Access denied' using errcode='42501';end if;
  if action='check_delivery' then
    select active_release_id into active_id from public.unsite_spaces where id=sid for update;
    if active_id is null then raise exception 'Publish a release before checking delivery';end if;
    select jsonb_build_object('id',id) into result from public.unsite_delivery_checks where space_id=sid and request_id=(p->>'request_id')::uuid;
    if found then return result;end if;
    if exists(select 1 from public.unsite_delivery_checks where space_id=sid and created_at>now()-interval '5 minutes') then raise exception 'Wait five minutes before checking delivery again';end if;
    insert into public.unsite_delivery_checks(space_id,release_id,request_id) values(sid,active_id,(p->>'request_id')::uuid) returning jsonb_build_object('id',id) into result;
    insert into public.unsite_events(space_id,actor_id,action,details) values(sid,auth.uid(),'delivery.check_requested',result);
    return result;
  end if;
  result:=unsite_private.presence_command_before_checks(action,p);
  if action='save_observation' then
    if p ? 'stale_answer' and jsonb_typeof(p->'stale_answer') not in ('null','boolean') then raise exception 'Invalid answer assessment';end if;
    update public.unsite_visibility_observations set stale_answer=(p->>'stale_answer')::boolean where id=(result->>'id')::uuid and space_id=sid;
  end if;
  return result;
end $$;
revoke all on function unsite_private.presence_command(text,jsonb) from public,anon;
grant execute on function unsite_private.presence_command(text,jsonb) to authenticated;

alter function unsite_private.presence_state(uuid) rename to presence_state_before_checks;
create function unsite_private.presence_state(sid uuid) returns jsonb language sql stable security invoker set search_path='' as $$
  select unsite_private.presence_state_before_checks(sid)||jsonb_build_object('delivery_checks',coalesce((select jsonb_agg(to_jsonb(c)-'lease_token'-'leased_until'-'request_id' order by created_at desc) from (select * from public.unsite_delivery_checks where space_id=sid order by created_at desc limit 20)c),'[]'));
$$;
revoke all on function unsite_private.presence_state(uuid) from public,anon;
grant execute on function unsite_private.presence_state(uuid) to authenticated;

alter function public.unsite_claim_maintenance() rename to unsite_claim_maintenance_before_checks;
create function public.unsite_claim_maintenance() returns jsonb language plpgsql security invoker set search_path='' as $$
declare c public.unsite_delivery_checks;
begin
  select * into c from public.unsite_delivery_checks where status='queued' or (status='running' and leased_until<now()) order by created_at for update skip locked limit 1;
  if not found then return public.unsite_claim_maintenance_before_checks();end if;
  update public.unsite_delivery_checks set status='running',lease_token=gen_random_uuid(),leased_until=now()+interval '90 seconds' where id=c.id returning * into c;
  return jsonb_build_object('kind','delivery','id',c.id,'space_id',c.space_id,'release_id',c.release_id,'lease',c.lease_token);
end $$;
revoke all on function public.unsite_claim_maintenance() from public,anon,authenticated;
grant execute on function public.unsite_claim_maintenance() to service_role;

alter function public.unsite_maintenance_result(text,uuid,uuid,jsonb) rename to unsite_maintenance_result_before_checks;
create function public.unsite_maintenance_result(p_kind text,p_id uuid,p_lease uuid,p_result jsonb) returns jsonb language plpgsql security invoker set search_path='' as $$
declare c public.unsite_delivery_checks;active_id uuid;report jsonb:=p_result;
begin
  if p_kind<>'delivery' then return public.unsite_maintenance_result_before_checks(p_kind,p_id,p_lease,p_result);end if;
  select * into c from public.unsite_delivery_checks where id=p_id for update;
  if not found or c.status<>'running' or c.lease_token is distinct from p_lease or c.leased_until<now() then return jsonb_build_object('saved',false);end if;
  if octet_length(p_result::text)>16000 then raise exception 'Delivery report too large';end if;
  select active_release_id into active_id from public.unsite_spaces where id=c.space_id;
  if active_id is distinct from c.release_id then report:=jsonb_build_object('error','The publication changed during this check. Check the current release again.');end if;
  if report ? 'error' then
    update public.unsite_delivery_checks set status='failed',error_message=left(report->>'error',1000),lease_token=null,leased_until=null where id=c.id;
  else
    if report->>'release_id' is distinct from c.release_id::text or report->>'mode' is distinct from 'direct_http_mcp' or jsonb_typeof(report->'checks') is distinct from 'array' then raise exception 'Invalid delivery report';end if;
    update public.unsite_delivery_checks set status='completed',result=report,lease_token=null,leased_until=null where id=c.id;
  end if;
  insert into public.unsite_events(space_id,action,details) values(c.space_id,'delivery.checked',jsonb_build_object('check_id',c.id,'release_id',c.release_id,'passed',coalesce((report->>'passed')::boolean,false)));
  return jsonb_build_object('saved',true);
end $$;
revoke all on function public.unsite_maintenance_result(text,uuid,uuid,jsonb) from public,anon,authenticated;
grant execute on function public.unsite_maintenance_result(text,uuid,uuid,jsonb) to service_role;

do $$ declare command_text text;begin
  select command into command_text from cron.job where jobname='unsite-process-sources';
  if command_text is not null then
    command_text:=regexp_replace(command_text,';\s*$','')||' or exists(select 1 from public.unsite_delivery_checks where status=''queued'' or (status=''running'' and leased_until<now()));';
    perform cron.schedule('unsite-process-sources','* * * * *',command_text);
  end if;
end $$;
