-- Private retrieval questions stay entirely in Postgres. No provider, HTTP query,
-- worker payload, or public projection receives these questions.
alter table public.unsite_delivery_checks add column index_results jsonb not null default '[]';
create function unsite_private.check_release_index() returns trigger language plpgsql security definer set search_path='' as $$
declare c public.unsite_retrieval_cases;ids uuid[];q tsquery;results jsonb:='[]';passed boolean;
begin
  for c in select * from public.unsite_retrieval_cases where space_id=new.space_id order by created_at,id loop
    q:=websearch_to_tsquery('english',c.question);
    select coalesce(array_agg(r.record_id order by r.score desc,r.record_id),'{}') into ids from (
      select record_id,ts_rank_cd(document,q) score from public.unsite_release_records where release_id=new.release_id and document@@q order by score desc,record_id limit 5
    ) r;
    passed:=case when c.expectation='no_match' then cardinality(ids)=0 else c.expected_record_id=any(ids) end;
    results:=results||jsonb_build_array(jsonb_build_object('case_id',c.id,'question',c.question,'passed',coalesce(passed,false),'returned_ids',to_jsonb(ids),'method','postgres_full_text','checked_at',now()));
  end loop;
  new.index_results:=results;
  return new;
end $$;
create trigger unsite_check_release_index before insert on public.unsite_delivery_checks for each row execute function unsite_private.check_release_index();
revoke all on function unsite_private.check_release_index() from public,anon,authenticated;

-- Automatic external checks use only a published release UUID and its public
-- resource endpoints. The task contains no private test questions or source data.
create function unsite_private.queue_release_checks() returns trigger language plpgsql security definer set search_path='' as $$
begin
  if new.active_release_id is not null and new.active_release_id is distinct from old.active_release_id then
    insert into public.unsite_delivery_checks(space_id,release_id,request_id) values(new.id,new.active_release_id,gen_random_uuid());
  end if;
  return new;
end $$;
create trigger unsite_queue_release_checks after update of active_release_id on public.unsite_spaces for each row execute function unsite_private.queue_release_checks();
revoke all on function unsite_private.queue_release_checks() from public,anon,authenticated;
