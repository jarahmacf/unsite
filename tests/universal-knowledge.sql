-- Rollback-only semantic persistence and publication checks. No outbound requests.
begin;
do $$
declare
  owner_uid uuid:=gen_random_uuid(); other_uid uuid:=gen_random_uuid(); sid uuid;
  space jsonb; entry jsonb; snap jsonb; published jsonb; item jsonb; ctx jsonb;
  legacy jsonb:='{"summary":"","aliases":[],"topics":[],"status":"unspecified","as_of":null}';
  entries jsonb:='[
    {"type_label":"Fictional scene","framing":"fiction","attribution":"Mira, the narrator"},
    {"type_label":"Research finding","framing":"source_claim","attribution":"The study authors"},
    {"type_label":"Company policy","framing":"instruction","attribution":"Example Company"},
    {"type_label":"Essay","framing":"opinion","attribution":"The essayist"},
    {"type_label":"Recipe","framing":"instruction","attribution":""},
    {"type_label":"Dataset notes","framing":"interpretation","attribution":"The analyst"}
  ]';
  original_context jsonb; denied boolean:=false;
begin
  assert unsite_private.valid_knowledge_context(legacy),'legacy context remains valid';
  for item in select value from jsonb_array_elements(entries) loop
    assert unsite_private.valid_knowledge_context(legacy||item),'flexible metadata is accepted';
  end loop;
  assert not unsite_private.valid_knowledge_context(legacy||'{"framing":"verified_truth"}'::jsonb),'unsupported framing is rejected';
  assert not unsite_private.valid_knowledge_context(legacy||'{"framing":null}'::jsonb),'null framing is rejected';
  assert not unsite_private.valid_knowledge_context(legacy||'{"type_label":42}'::jsonb),'non-string labels are rejected';
  assert not unsite_private.valid_knowledge_context(legacy||'{"attribution":[]}'::jsonb),'non-string attribution is rejected';
  assert not unsite_private.valid_knowledge_context(legacy||jsonb_build_object('type_label',repeat('x',101))),'type label limit';
  assert not unsite_private.valid_knowledge_context(legacy||jsonb_build_object('attribution',repeat('x',601))),'attribution limit';
  assert not unsite_private.valid_knowledge_context(legacy||'{"private_note":"hidden"}'::jsonb),'unknown metadata cannot enter a public context';

  insert into auth.users(id,aud,role,email) values
    (owner_uid,'authenticated','authenticated',owner_uid::text||'@example.invalid'),
    (other_uid,'authenticated','authenticated',other_uid::text||'@example.invalid');
  perform set_config('request.jwt.claim.sub',owner_uid::text,true);
  set local role authenticated;
  space:=public.unsite_command('create_space',jsonb_build_object('name','Mixed material','kind','collection','request_id',gen_random_uuid()));
  sid:=(space->>'id')::uuid;
  for item in select value from jsonb_array_elements(entries) loop
    ctx:=legacy||item;
    entry:=public.unsite_command('create_record',jsonb_build_object(
      'space_id',sid,'kind','general','title',item->>'type_label','text','Source-supported material with its original perspective preserved.',
      'fields','{"amount":2.5,"optional":false,"unknown":null,"unit":"grams"}'::jsonb,'context',ctx,'request_id',gen_random_uuid()));
    assert entry->'context'=ctx,'metadata round-trips without type-specific schemas';
    assert entry->'fields'->'optional'='false'::jsonb,'false remains a boolean';
    assert entry->'fields'->'amount'='2.5'::jsonb,'numeric values retain their type';
  end loop;
  snap:=public.unsite_knowledge_snapshot(sid);
  assert jsonb_array_length(snap->'snapshot'->'records')=6,'mixed content coexists in one collection';
  assert (select count(distinct value->'context'->>'type_label') from jsonb_array_elements(snap->'snapshot'->'records'))=6,'no category collapse';
  assert (select value->'context'->>'attribution'='Mira, the narrator' from jsonb_array_elements(snap->'snapshot'->'records') where value->'context'->>'framing'='fiction'),'fiction perspective survives projection';
  assert (select bool_and(value->'fields'->'unknown'='null'::jsonb) from jsonb_array_elements(snap->'snapshot'->'records')),'unknown values stay explicit';
  published:=public.unsite_command('publish_release',jsonb_build_object('space_id',sid,'revision',snap->>'source_revision','reviewed',true,'request_id',gen_random_uuid()));
  assert (select data from public.unsite_releases where id=(published->>'id')::uuid)=snap->'snapshot','published JSON exactly preserves approved semantics';
  original_context:=entry->'context';
  perform public.unsite_command('edit_record',jsonb_build_object(
    'space_id',sid,'record_id',entry->>'id','revision',entry->'revision','kind','general','title','Revised notes','text','Revised perspective.',
    'fields','{}'::jsonb,'context',original_context||'{"framing":"mixed"}'::jsonb,'active',true));
  assert (select value->'context'=original_context from public.unsite_releases r, jsonb_array_elements(r.data->'records') where r.id=(published->>'id')::uuid and value->>'id'=entry->>'id'),'editing interpretation cannot rewrite an approved release';
  perform set_config('request.jwt.claim.sub',other_uid::text,true);
  assert public.unsite_knowledge_snapshot(sid) is null,'mixed-content draft remains tenant isolated';
  reset role;
end $$;
rollback;
select 'PASS: flexible content metadata, legacy compatibility, typed values, mixed collections, exact immutable publication and tenant isolation' as result;
