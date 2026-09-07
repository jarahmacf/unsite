-- Preserve ambiguous outcomes for stopped or expired requests.
create or replace function public.unsite_claim_job() returns jsonb language plpgsql security invoker set search_path='' as $$
declare j public.unsite_jobs;
begin
  -- An expired provider lease must never silently issue a second paid request.
  update public.unsite_ai_attempts a set status='uncertain',finished_at=now() from public.unsite_jobs active_job
    where a.job_id=active_job.id and a.status='in_flight' and (active_job.status<>'running' or active_job.lease_token is distinct from a.lease_token or active_job.leased_until<now());
  update public.unsite_jobs set status='blocked',stage='review needed',error_code='PROVIDER_UNCERTAIN',error_message='The AI request ended without a saved checkpoint. Retry when ready; a repeated request may incur another provider charge.',lease_token=null,leased_until=null,updated_at=now()
    where status='running' and stage='preparing with AI' and leased_until<now();
  update public.unsite_jobs set status='failed',stage='failed',error_code='LEASE_EXHAUSTED',error_message='Processing stopped before completion. Retry to continue from the saved checkpoint.',lease_token=null,leased_until=null,updated_at=now()
    where status='running' and leased_until<now() and attempts>=max_attempts;
  select * into j from public.unsite_jobs where (status='queued' and run_after<=now() or status='running' and leased_until<now()) and attempts<max_attempts order by created_at for update skip locked limit 1;
  if not found then return null; end if;
  update public.unsite_jobs set status='running',stage=case when cursor=0 then 'reading' else 'preparing' end,attempts=attempts+1,lease_token=gen_random_uuid(),leased_until=now()+interval '150 seconds',updated_at=now() where id=j.id returning * into j;
  return to_jsonb(j);
end $$;

create or replace function public.unsite_ai_finish(p_dispatch_id uuid,p_status text,p_response_id text default null,p_input_tokens integer default null,p_output_tokens integer default null) returns boolean
language plpgsql security invoker set search_path='' as $$
begin
  if p_status is null or p_status not in ('succeeded','failed','uncertain') then raise exception 'Invalid attempt status'; end if;
  update public.unsite_ai_attempts set status=p_status,finished_at=now(),provider_response_id=left(p_response_id,200),input_tokens=p_input_tokens,output_tokens=p_output_tokens
    where id=p_dispatch_id and status in ('in_flight','uncertain');
  return found;
end $$;
