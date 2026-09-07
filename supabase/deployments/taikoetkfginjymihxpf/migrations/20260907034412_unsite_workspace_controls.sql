-- Additive workspace controls. Public functions are SECURITY INVOKER;
-- privileged work stays in unsite_private and checks identity and workspace role.
create table public.unsite_invitations (
  id uuid primary key default gen_random_uuid(),
  space_id uuid not null references public.unsite_spaces(id) on delete cascade,
  email text not null check(email=lower(btrim(email)) and length(email) between 3 and 254 and position('@' in email)>1),
  role text not null check(role in ('editor','viewer')),
  token_hash text not null check(token_hash ~ '^[0-9a-f]{64}$'),
  request_id uuid not null,
  created_by uuid not null references auth.users(id),
  created_at timestamptz not null default now(),
  expires_at timestamptz not null default now()+interval '7 days',
  accepted_by uuid references auth.users(id), accepted_at timestamptz, revoked_at timestamptz,
  unique(space_id,request_id)
);
create index unsite_invitations_space_created on public.unsite_invitations(space_id,created_at desc);
create index unsite_invitations_created_by on public.unsite_invitations(created_by);
create index unsite_invitations_accepted_by on public.unsite_invitations(accepted_by) where accepted_by is not null;
alter table public.unsite_invitations enable row level security;
revoke all on public.unsite_invitations from public,anon,authenticated;
grant all on public.unsite_invitations to service_role;
-- Token hashes are never exposed through direct customer table access.

create function unsite_private.workspace_settings(target uuid) returns jsonb
language plpgsql stable security definer set search_path='' as $$
begin
  if auth.uid() is null or not unsite_private.is_member(target) then raise exception 'Access denied' using errcode='42501'; end if;
  return jsonb_build_object(
    'members',(select coalesce(jsonb_agg(jsonb_build_object('user_id',m.user_id,'email',u.email,'role',m.role,'created_at',m.created_at) order by m.created_at),'[]') from public.unsite_memberships m join auth.users u on u.id=m.user_id where m.space_id=target),
    'invitations',case when unsite_private.is_member(target,array['owner']) then (select coalesce(jsonb_agg(to_jsonb(i) order by i.created_at desc),'[]') from (select id,email,role,created_at,expires_at,accepted_at,revoked_at from public.unsite_invitations where space_id=target order by created_at desc limit 100) i) else '[]'::jsonb end,
    'usage',jsonb_build_object(
      'sources',(select count(*) from public.unsite_sources where space_id=target and archived_at is null),
      'archived_sources',(select count(*) from public.unsite_sources where space_id=target and archived_at is not null),
      'versions',(select count(*) from public.unsite_source_versions where space_id=target),
      'stored_bytes',(select coalesce(sum(byte_size),0) from public.unsite_source_versions where space_id=target and storage_path is not null),
      'records',(select count(*) from public.unsite_records where space_id=target),
      'included_records',(select count(*) from public.unsite_records where space_id=target and active),
      'pending_reviews',(select count(*) from public.unsite_candidates where space_id=target and status='proposed' and review_ready),
      'releases',(select count(*) from public.unsite_releases where space_id=target),
      'events',(select count(*) from public.unsite_events where space_id=target)
    )
  );
end $$;

create function unsite_private.workspace_command(action text,p jsonb) returns jsonb
language plpgsql security definer set search_path='' as $$
declare
  uid uuid:=auth.uid(); sid uuid; sp public.unsite_spaces; inv public.unsite_invitations;
  member public.unsite_memberships; result jsonb; actor_email text;
begin
  if uid is null then raise exception 'Access denied' using errcode='42501'; end if;
  if p is null or pg_column_size(p)>10000 then raise exception 'Invalid workspace request'; end if;
  if action='accept_invitation' then
    select space_id into sid from public.unsite_invitations where id=(p->>'invitation_id')::uuid;
    if sid is null then raise exception 'Invitation is unavailable'; end if;
  else sid:=(p->>'space_id')::uuid; end if;
  select * into sp from public.unsite_spaces where id=sid for update;
  if not found then raise exception 'Workspace not found'; end if;
  if action='accept_invitation' then
    select * into inv from public.unsite_invitations where id=(p->>'invitation_id')::uuid and space_id=sid for update;
    select lower(email) into actor_email from auth.users where id=uid and email_confirmed_at is not null;
    if inv.id is null or inv.revoked_at is not null or coalesce(p->>'token','') !~ '^[0-9a-f]{64}$'
      or inv.token_hash is distinct from encode(extensions.digest(p->>'token','sha256'),'hex')
      or actor_email is distinct from inv.email then raise exception 'Invitation is unavailable for this account'; end if;
    if inv.accepted_at is not null then
      if inv.accepted_by=uid and unsite_private.is_member(sid) then return jsonb_build_object('space_id',sid); end if;
      raise exception 'Invitation is unavailable';
    end if;
    if inv.expires_at<=now() then raise exception 'Invitation has expired'; end if;
    if (select count(*) from public.unsite_memberships where space_id=sid)>=25 then raise exception 'Workspace member limit reached'; end if;
    insert into public.unsite_memberships(space_id,user_id,role) values(sid,uid,inv.role) on conflict(space_id,user_id) do nothing;
    update public.unsite_invitations set accepted_by=uid,accepted_at=now() where id=inv.id;
    result:=jsonb_build_object('space_id',sid);
  elsif action='restore_source' then
    if not unsite_private.is_member(sid,array['owner','editor']) then raise exception 'Access denied' using errcode='42501'; end if;
    update public.unsite_sources set archived_at=null where space_id=sid and id=(p->>'source_id')::uuid returning to_jsonb(unsite_sources.*) into result;
    if result is null then raise exception 'Source not found'; end if;
  elsif action='leave_workspace' then
    if not unsite_private.is_member(sid) or sp.owner_id=uid then raise exception 'The workspace owner cannot leave'; end if;
    delete from public.unsite_memberships where space_id=sid and user_id=uid;
    result:=jsonb_build_object('space_id',sid);
  else
    if not unsite_private.is_member(sid,array['owner']) or sp.owner_id<>uid then raise exception 'Access denied' using errcode='42501'; end if;
    if action='create_invitation' then
      if coalesce(p->>'role','') not in ('editor','viewer') or coalesce(p->>'token','') !~ '^[0-9a-f]{64}$' then raise exception 'Invalid invitation'; end if;
      select * into inv from public.unsite_invitations where space_id=sid and request_id=(p->>'request_id')::uuid;
      if found then
        if inv.token_hash is distinct from encode(extensions.digest(p->>'token','sha256'),'hex') then raise exception 'Invitation request already exists'; end if;
        return jsonb_build_object('id',inv.id,'email',inv.email,'role',inv.role,'expires_at',inv.expires_at);
      end if;
      if exists(select 1 from public.unsite_memberships m join auth.users u on u.id=m.user_id where m.space_id=sid and lower(u.email)=lower(btrim(p->>'email'))) then raise exception 'This person already has access'; end if;
      if (select count(*) from public.unsite_invitations where space_id=sid and accepted_at is null and revoked_at is null and expires_at>now())>=20 then raise exception 'Too many pending invitations'; end if;
      insert into public.unsite_invitations(space_id,email,role,token_hash,request_id,created_by)
        values(sid,lower(btrim(p->>'email')),p->>'role',encode(extensions.digest(p->>'token','sha256'),'hex'),(p->>'request_id')::uuid,uid) returning * into inv;
      result:=jsonb_build_object('id',inv.id,'email',inv.email,'role',inv.role,'expires_at',inv.expires_at);
    elsif action='revoke_invitation' then
      update public.unsite_invitations set revoked_at=coalesce(revoked_at,now()) where id=(p->>'invitation_id')::uuid and space_id=sid and accepted_at is null returning jsonb_build_object('id',id) into result;
      if result is null then raise exception 'Invitation is unavailable'; end if;
    elsif action in ('update_member','remove_member') then
      select * into member from public.unsite_memberships where space_id=sid and user_id=(p->>'user_id')::uuid for update;
      if not found then raise exception 'Member not found'; end if;
      if member.user_id=sp.owner_id or member.role='owner' then raise exception 'Owner access cannot be changed here'; end if;
      if action='update_member' then
        if coalesce(p->>'role','') not in ('editor','viewer') then raise exception 'Choose editor or viewer access'; end if;
        update public.unsite_memberships set role=p->>'role' where space_id=sid and user_id=member.user_id;
      else delete from public.unsite_memberships where space_id=sid and user_id=member.user_id; end if;
      result:=jsonb_build_object('user_id',member.user_id);
    else raise exception 'Unknown workspace command'; end if;
  end if;
  insert into public.unsite_events(space_id,actor_id,action,details) values(sid,uid,action,jsonb_build_object('user_id',p->>'user_id','source_id',p->>'source_id'));
  return result;
end $$;

create function unsite_private.record_directory(target uuid,search_query text,content_type text,inclusion text,page_offset integer,page_limit integer) returns jsonb
language plpgsql stable security invoker set search_path='' as $$
begin
  if auth.uid() is null or not unsite_private.is_member(target) then raise exception 'Access denied' using errcode='42501'; end if;
  if page_offset is null or page_offset<0 or page_limit is null or page_limit<1 or page_limit>100 or length(coalesce(search_query,''))>300 or length(coalesce(content_type,''))>100 or inclusion is null or inclusion not in ('all','included','excluded') then raise exception 'Invalid directory filter'; end if;
  return (
    with catalog as (
      select r.*,coalesce(nullif(btrim(r.context->>'type_label'),''),case r.kind when 'about' then 'Overview' when 'faq' then 'Question & answer' when 'general' then 'Knowledge' else initcap(r.kind) end) as type_label
      from public.unsite_records r where r.space_id=target
    ), filtered as (
      select * from catalog r where (coalesce(content_type,'')='' or lower(normalize(r.type_label,NFKC))=lower(normalize(btrim(content_type),NFKC)))
        and (inclusion='all' or (inclusion='included' and r.active) or (inclusion='excluded' and not r.active))
        and (coalesce(btrim(search_query),'')='' or strpos(lower(normalize(concat_ws(' ',r.title,r.text,r.fields::text,r.context::text),NFKC)),lower(normalize(btrim(search_query),NFKC)))>0)
    ) select jsonb_build_object(
      'items',(select coalesce(jsonb_agg(to_jsonb(p)-'type_label' order by p.updated_at desc,p.id),'[]') from (select * from filtered order by updated_at desc,id offset page_offset limit page_limit) p),
      'count',(select count(*) from filtered),
      'types',(select coalesce(jsonb_agg(type_label order by type_label),'[]') from (select distinct type_label from catalog) t)
    )
  );
end $$;

create function unsite_private.workspace_export(target uuid) returns jsonb
language plpgsql stable security invoker set search_path='' as $$
begin
  if auth.uid() is null or not unsite_private.is_member(target,array['owner']) then raise exception 'Access denied' using errcode='42501'; end if;
  return jsonb_build_object('format','unsite-workspace-1','exported_at',now(),
    'space',(select to_jsonb(s)-'request_id' from public.unsite_spaces s where id=target),
    'records',(select coalesce(jsonb_agg(to_jsonb(r)-'request_id'),'[]') from public.unsite_records r where space_id=target),
    'relationships',(select coalesce(jsonb_agg(to_jsonb(r)),'[]') from public.unsite_record_links r where space_id=target),
    'sources',(select coalesce(jsonb_agg(to_jsonb(s)-'created_by'),'[]') from public.unsite_sources s where space_id=target),
    'source_versions',(select coalesce(jsonb_agg(to_jsonb(v)-'storage_path'-'request_id'),'[]') from public.unsite_source_versions v where space_id=target),
    'review',(select coalesce(jsonb_agg(to_jsonb(c)),'[]') from public.unsite_candidates c where space_id=target),
    'evidence_history',(select coalesce(jsonb_agg(to_jsonb(e)),'[]') from public.unsite_record_evidence e where space_id=target),
    'releases',(select coalesce(jsonb_agg(to_jsonb(r)-'request_id'),'[]') from public.unsite_releases r where space_id=target),
    'note','Original uploaded files are downloaded individually from Sources. Invitations, account credentials and processing credentials are excluded.'
  );
end $$;

create function public.unsite_workspace_settings(space_id uuid) returns jsonb language sql stable security invoker set search_path='' as $$select unsite_private.workspace_settings(space_id);$$;
create function public.unsite_workspace_command(action text,payload jsonb) returns jsonb language sql security invoker set search_path='' as $$select unsite_private.workspace_command(action,payload);$$;
create function public.unsite_record_directory(space_id uuid,search_query text default '',content_type text default '',inclusion text default 'all',page_offset integer default 0,page_limit integer default 24) returns jsonb language sql stable security invoker set search_path='' as $$select unsite_private.record_directory(space_id,search_query,content_type,inclusion,page_offset,page_limit);$$;
create function public.unsite_workspace_export(space_id uuid) returns jsonb language sql stable security invoker set search_path='' as $$select unsite_private.workspace_export(space_id);$$;

revoke all on function unsite_private.workspace_settings(uuid),unsite_private.workspace_command(text,jsonb),unsite_private.record_directory(uuid,text,text,text,integer,integer),unsite_private.workspace_export(uuid),public.unsite_workspace_settings(uuid),public.unsite_workspace_command(text,jsonb),public.unsite_record_directory(uuid,text,text,text,integer,integer),public.unsite_workspace_export(uuid) from public,anon;
grant execute on function unsite_private.workspace_settings(uuid),unsite_private.workspace_command(text,jsonb),unsite_private.record_directory(uuid,text,text,text,integer,integer),unsite_private.workspace_export(uuid),public.unsite_workspace_settings(uuid),public.unsite_workspace_command(text,jsonb),public.unsite_record_directory(uuid,text,text,text,integer,integer),public.unsite_workspace_export(uuid) to authenticated;
