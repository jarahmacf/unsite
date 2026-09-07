-- The sitemap enumerates only the current public pointer, including record pages.
create function public.unsite_public_sitemap(page_offset integer default 0,page_limit integer default 5000) returns jsonb language sql stable security invoker set search_path='' as $$
  with live as (select sp.id,sp.active_release_id,rel.published_at from public.unsite_spaces sp join public.unsite_releases rel on rel.id=sp.active_release_id),
  urls as (select '/p/'||id::text path,published_at from live union all select '/p/'||l.id::text||'/records/'||r.record_id::text,l.published_at from live l join public.unsite_release_records r on r.release_id=l.active_release_id)
  select jsonb_build_object('total',(select count(*) from urls),'items',coalesce((select jsonb_agg(page order by path) from (select * from urls order by path offset greatest(0,page_offset) limit least(5000,greatest(1,page_limit))) page),'[]'));
$$;
revoke all on function public.unsite_public_sitemap(integer,integer) from public,anon,authenticated;
grant execute on function public.unsite_public_sitemap(integer,integer) to service_role;

-- Private source identities help route renamed or revised knowledge. They are
-- never added to the public snapshot or inferred as evidence for fresh claims.
create function unsite_private.freeze_source_dependencies() returns trigger language plpgsql security definer set search_path='' as $$
begin
  new.knowledge_snapshot:=jsonb_set(new.knowledge_snapshot,'{records}',coalesce((
    select jsonb_agg(rec||jsonb_build_object('source_ids',coalesce((
      select jsonb_agg(dependency.source_id order by dependency.source_id) from (
        select sv.source_id from public.unsite_records kr join public.unsite_candidates c on c.id=kr.candidate_id
          join public.unsite_source_versions sv on sv.id=c.source_version_id where kr.space_id=new.space_id and kr.id=(rec->>'id')::uuid
        union
        select sv.source_id from public.unsite_records kr join public.unsite_candidates c on c.id=kr.candidate_id
          cross join lateral jsonb_array_elements(c.evidence) ev join public.unsite_source_versions sv on sv.id=(ev->>'source_version_id')::uuid
          where kr.space_id=new.space_id and kr.id=(rec->>'id')::uuid and sv.space_id=new.space_id
      ) dependency),'[]'::jsonb))) from jsonb_array_elements(new.knowledge_snapshot->'records') rec),'[]'::jsonb));
  return new;
end $$;
revoke all on function unsite_private.freeze_source_dependencies() from public,anon,authenticated;
create trigger unsite_freeze_source_dependencies before insert on public.unsite_collection_runs for each row execute function unsite_private.freeze_source_dependencies();

create or replace function public.unsite_collection_context(p_task_id uuid,p_lease uuid) returns jsonb language sql stable security invoker set search_path='' as $$
  select jsonb_build_object('run',to_jsonb(r),'segments',coalesce((select jsonb_agg(to_jsonb(e)||jsonb_build_object('source_id',sv.source_id) order by e.ordinal,e.source_version_id)
      from public.unsite_evidence_segments e join public.unsite_collection_inputs i on i.source_version_id=e.source_version_id join public.unsite_source_versions sv on sv.id=e.source_version_id where i.run_id=r.id),'[]'::jsonb),
    'extractions',coalesce((select jsonb_agg(jsonb_build_object('id',x.id,'input',x.input,'output',x.output) order by x.ordinal) from public.unsite_collection_tasks x where x.run_id=r.id and x.stage='extract' and x.status='completed'),'[]'::jsonb),
    'curated',(select output from public.unsite_collection_tasks c where c.run_id=r.id and c.id=(t.input->>'curate_task_id')::uuid and c.stage='curate' and c.status='completed'))
  from public.unsite_collection_tasks t join public.unsite_collection_runs r on r.id=t.run_id where t.id=p_task_id and t.status='running' and t.lease_token=p_lease and t.leased_until>now() and r.status='running' and r.revoked_at is null;
$$;

alter function unsite_private.workspace_export(uuid) rename to workspace_export_before_geo;
create function unsite_private.workspace_export(target uuid) returns jsonb language sql stable security invoker set search_path='' as $$
  select unsite_private.workspace_export_before_geo(target)||jsonb_build_object('presence',unsite_private.presence_state(target),
    'visibility_observations',(select coalesce(jsonb_agg(to_jsonb(o)-'created_by'-'request_id' order by observed_at desc),'[]') from public.unsite_visibility_observations o where space_id=target));
$$;
revoke all on function unsite_private.workspace_export(uuid) from public,anon;
grant execute on function unsite_private.workspace_export(uuid) to authenticated;

-- Keep explicit empty policies for service-only tables; no anonymous or customer
-- table projection can bypass the active-publication checks in service RPCs.
create policy service_only on public.unsite_release_catalog for all to service_role using(true) with check(true);
create policy service_only on public.unsite_release_records for all to service_role using(true) with check(true);
create policy service_only on public.unsite_public_read_windows for all to service_role using(true) with check(true);
