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
