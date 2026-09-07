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
