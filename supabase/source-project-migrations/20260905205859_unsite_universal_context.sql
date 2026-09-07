-- Optional domain-independent metadata; existing contexts and releases remain valid.
create or replace function unsite_private.valid_knowledge_context(c jsonb) returns boolean
language plpgsql immutable security invoker set search_path='' as $$
declare x jsonb; k text;
begin
  if c is null or jsonb_typeof(c)<>'object' or pg_column_size(c)>12000 then return false; end if;
  if exists(select 1 from jsonb_object_keys(c) as context_keys(name) where context_keys.name not in ('summary','aliases','topics','status','as_of','type_label','framing','attribution')) then return false; end if;
  if jsonb_typeof(c->'summary') is distinct from 'string' or length(c->>'summary')>1200 or coalesce(c->>'status','') not in ('unspecified','current','historical','uncertain') then return false; end if;
  if c ? 'type_label' and (jsonb_typeof(c->'type_label') is distinct from 'string' or length(c->>'type_label')>100) then return false; end if;
  if c ? 'attribution' and (jsonb_typeof(c->'attribution') is distinct from 'string' or length(c->>'attribution')>600) then return false; end if;
  if c ? 'framing' and coalesce(c->>'framing','') not in ('unspecified','source_claim','opinion','fiction','instruction','interpretation','mixed') then return false; end if;
  foreach k in array array['aliases','topics'] loop
    if jsonb_typeof(c->k) is distinct from 'array' or jsonb_array_length(c->k)>20 then return false; end if;
    for x in select value from jsonb_array_elements(c->k) loop
      if jsonb_typeof(x)<>'string' or length(btrim(x#>>'{}')) not between 1 and 100 then return false; end if;
    end loop;
  end loop;
  if not(c ? 'as_of') then return false; end if;
  if c->'as_of'<>'null'::jsonb then
    if jsonb_typeof(c->'as_of')<>'string' or (c->>'as_of')!~'^\d{4}-\d{2}-\d{2}$' then return false; end if;
    perform (c->>'as_of')::date;
  end if;
  return true;
exception when others then return false;
end $$;
