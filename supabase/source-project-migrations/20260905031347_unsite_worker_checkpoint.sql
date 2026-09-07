-- Avoid the job_id parameter shadowing the unique conflict target.
create or replace function public.unsite_job_result(job_id uuid,lease uuid,result jsonb) returns boolean language plpgsql security invoker set search_path='' as $$
declare j public.unsite_jobs; item jsonb; n integer:=0; warnings jsonb;
begin
  select * into j from public.unsite_jobs where id=job_id for update;
  if not found or j.status<>'running' or j.lease_token is distinct from lease or j.leased_until<now() then return false; end if;
  if result->>'mode'='parsed' then
    update public.unsite_source_versions set extracted_text=result->>'text',content_hash=result->>'hash' where id=j.source_version_id;
    update public.unsite_jobs set chunk_count=(result->>'chunks')::integer,stage='preparing',progress=10,leased_until=now()+interval '150 seconds',updated_at=now() where id=j.id;
  elsif result->>'mode'='chunk' then
    if (result->>'cursor')::integer<>j.cursor then return false; end if;
    for item in select value from jsonb_array_elements(result->'candidates') loop
      warnings := coalesce(item->'warnings','[]');
      if exists(select 1 from public.unsite_records r where r.space_id=j.space_id and r.active and r.kind=item->>'kind' and lower(r.title)=lower(item->>'title'))
        or exists(select 1 from public.unsite_candidates c where c.space_id=j.space_id and c.kind=item->>'kind' and lower(c.title)=lower(item->>'title') and c.status='proposed') then
        warnings := warnings||'"A similar entry exists. Compare it before adding or replacing content."'::jsonb;
      end if;
      insert into public.unsite_candidates(space_id,source_version_id,job_id,chunk_index,item_index,kind,title,text,fields,evidence,warnings)
      values(j.space_id,j.source_version_id,j.id,j.cursor,n,item->>'kind',item->>'title',item->>'text',item->'fields',item->'evidence',warnings) on conflict do nothing;
      n:=n+1;
    end loop;
    update public.unsite_jobs set cursor=cursor+1,status=case when cursor+1>=chunk_count then 'completed' else 'queued' end,
      stage=case when cursor+1>=chunk_count then 'ready for review' else 'preparing' end,
      progress=case when cursor+1>=chunk_count then 100 else least(95,10+(85*(cursor+1)/greatest(chunk_count,1))) end,
      attempts=0,lease_token=null,leased_until=null,run_after=now(),updated_at=now(),error_code=null,error_message=null where id=j.id;
    if j.cursor+1>=j.chunk_count then insert into public.unsite_events(space_id,action,details) values(j.space_id,'source.prepared',jsonb_build_object('id',j.source_version_id)); end if;
  elsif result->>'mode'='error' then
    update public.unsite_jobs set status=case when result->>'disposition'='retry' and attempts<max_attempts then 'queued' when result->>'disposition'='blocked' then 'blocked' else 'failed' end,
      stage=case when result->>'disposition'='blocked' then 'setup needed' else 'interrupted' end,
      error_code=left(result->>'code',100),error_message=left(result->>'message',1000),run_after=now()+make_interval(secs=>least(300,30*attempts)),lease_token=null,leased_until=null,updated_at=now() where id=j.id;
  else raise exception 'Unknown worker result';
  end if;
  return true;
end $$;
