-- Requires unsite_worker_key, unsite_worker_gateway and unsite_worker_url in Vault.
-- The worker is verified by the Supabase gateway AND a separate scoped credential.
-- No source content is passed through cron or the network request queue.
select cron.schedule('unsite-process-sources','* * * * *',$job$
  select net.http_post(
    url := (select decrypted_secret from vault.decrypted_secrets where name='unsite_worker_url'),
    headers := jsonb_build_object(
      'Content-Type','application/json',
      'Authorization','Bearer '||(select decrypted_secret from vault.decrypted_secrets where name='unsite_worker_gateway'),
      'X-Unsite-Worker-Key',(select decrypted_secret from vault.decrypted_secrets where name='unsite_worker_key')
    ),
    body := '{}'::jsonb,
    timeout_milliseconds := 5000
  ) where exists (
    select 1 from public.unsite_jobs
    where status='queued' and run_after<=now()
       or status='running' and leased_until<now()
  ) or exists (
    select 1 from public.unsite_collection_runs
    where status in ('waiting','running') and revoked_at is null
  );
$job$);
