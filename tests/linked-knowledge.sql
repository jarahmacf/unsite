-- No outbound requests. All accounts, sources, records and releases roll back.
begin;
do $$
declare
  owner_uid uuid:=gen_random_uuid(); other_uid uuid:=gen_random_uuid(); viewer_uid uuid:=gen_random_uuid();
  sid uuid; other_sid uuid; target_id uuid; entry_id uuid; foreign_id uuid;
  create_request uuid:=gen_random_uuid(); case_request uuid:=gen_random_uuid(); candidate_a uuid:=gen_random_uuid(); candidate_b uuid:=gen_random_uuid();
  space jsonb; entry jsonb; target jsonb; version_a jsonb; version_b jsonb; snap jsonb; release jsonb; second_release jsonb; case_row jsonb;
  context jsonb:='{"summary":"Atlas is the deployment research project.","aliases":["Atlas"],"topics":["Research","Deployment"],"status":"uncertain","as_of":"2026-09-01"}';
  before_revision integer; denied boolean; i integer;
begin
  insert into auth.users(id,aud,role,email) values
    (owner_uid,'authenticated','authenticated',owner_uid::text||'@example.invalid'),
    (other_uid,'authenticated','authenticated',other_uid::text||'@example.invalid'),
    (viewer_uid,'authenticated','authenticated',viewer_uid::text||'@example.invalid');
  perform set_config('request.jwt.claim.sub',other_uid::text,true);
  set local role authenticated;
  space:=public.unsite_command('create_space',jsonb_build_object('name','Other collection','kind','collection','request_id',gen_random_uuid()));other_sid:=(space->>'id')::uuid;
  entry:=public.unsite_command('create_record',jsonb_build_object('space_id',other_sid,'title','Project Atlas','kind','project','text','OTHER_TENANT_PRIVATE','fields','{}'::jsonb,'request_id',gen_random_uuid()));foreign_id:=(entry->>'id')::uuid;
  perform set_config('request.jwt.claim.sub',owner_uid::text,true);
  space:=public.unsite_command('create_space',jsonb_build_object('name','Atlas context','kind','project','request_id',gen_random_uuid()));sid:=(space->>'id')::uuid;
  assert space->>'kind'='project','project spaces supported';
  target:=public.unsite_command('create_record',jsonb_build_object('space_id',sid,'title','Rae','kind','person','text','Rae owns the Atlas project.','fields','{}'::jsonb,'request_id',gen_random_uuid()));target_id:=(target->>'id')::uuid;
  entry:=public.unsite_command('create_record',jsonb_build_object('space_id',sid,'title','Project Atlas','kind','project','text','Atlas investigates deployment options. The launch date is not decided.','fields','{"launch_date":null,"owner":"Rae"}'::jsonb,'context',context,'links',jsonb_build_array(jsonb_build_object('target_id',target_id,'relation','created_by')),'request_id',create_request));entry_id:=(entry->>'id')::uuid;
  assert entry->'context'=context,'knowledge context round-trips';
  perform public.unsite_command('create_record',jsonb_build_object('space_id',sid,'title','replayed','kind','project','text','overwrite','fields','{}'::jsonb,'links','[]'::jsonb,'request_id',create_request));
  assert (select count(*) from public.unsite_record_links where record_id=entry_id)=1,'idempotent create cannot remove relationships';
  select content_revision into before_revision from public.unsite_spaces where id=sid;
  denied:=false;begin
    perform public.unsite_command('edit_record',jsonb_build_object('space_id',sid,'record_id',entry_id,'revision',1,'title','Bad replacement','kind','project','text','Should not persist','fields','{}'::jsonb,'active',true,'links',jsonb_build_array(jsonb_build_object('target_id',foreign_id,'relation','depends_on'))));
  exception when raise_exception then denied:=SQLERRM='Relationship target not found';end;
  assert denied,'cross-tenant target rejected';
  assert (select revision=1 and title='Project Atlas' from public.unsite_records where id=entry_id),'failed relationship update is atomic';
  assert (select content_revision from public.unsite_spaces where id=sid)=before_revision,'failed update keeps publication revision';
  assert (select count(*) from public.unsite_record_links where record_id=entry_id)=1,'failed update preserves existing links';
  denied:=false;begin
    perform public.unsite_command('edit_record',jsonb_build_object('space_id',sid,'record_id',entry_id,'revision',1,'title','Project Atlas','kind','project','text','Self link','fields','{}'::jsonb,'active',true,'links',jsonb_build_array(jsonb_build_object('target_id',entry_id,'relation','related_to'))));
  exception when check_violation then denied:=true;end;assert denied,'self-link rejected';
  denied:=false;begin
    perform public.unsite_command('edit_record',jsonb_build_object('space_id',sid,'record_id',entry_id,'revision',1,'title','Project Atlas','kind','project','text','Bad date','fields','{}'::jsonb,'active',true,'context',context||'{"as_of":"2026-02-30"}'::jsonb));
  exception when check_violation then denied:=true;end;assert denied,'impossible knowledge date rejected';
  case_row:=public.unsite_retrieval_case_command('save_retrieval_case',jsonb_build_object('space_id',sid,'question','Who owns Atlas?','expectation','find','expected_record_id',entry_id,'request_id',case_request));
  assert public.unsite_retrieval_case_command('save_retrieval_case',jsonb_build_object('space_id',sid,'question','Changed replay','expectation','no_match','request_id',case_request))->>'id'=case_row->>'id','saved questions are idempotent';
  denied:=false;begin
    perform public.unsite_retrieval_case_command('save_retrieval_case',jsonb_build_object('space_id',sid,'question','Other tenant','expectation','find','expected_record_id',foreign_id,'request_id',gen_random_uuid()));
  exception when foreign_key_violation then denied:=true;end;assert denied,'test expectations cannot reference another tenant';
  for i in 2..20 loop
    perform public.unsite_retrieval_case_command('save_retrieval_case',jsonb_build_object('space_id',sid,'question','Absent test term '||i,'expectation','no_match','request_id',gen_random_uuid()));
  end loop;
  denied:=false;begin
    perform public.unsite_retrieval_case_command('save_retrieval_case',jsonb_build_object('space_id',sid,'question','Too many questions','expectation','no_match','request_id',gen_random_uuid()));
  exception when raise_exception then denied:=SQLERRM='Retrieval case limit reached';end;assert denied,'bounded saved test count';
  version_a:=public.unsite_command('source_intake',jsonb_build_object('space_id',sid,'title','Private project notes','kind','text','text_content','PRIVATE_ORIGINAL_MARK: project evidence.','request_id',gen_random_uuid()));
  version_b:=public.unsite_command('source_intake',jsonb_build_object('space_id',sid,'title','Private project notes','source_id',version_a->>'source_id','kind','text','text_content','PRIVATE_ORIGINAL_MARK: updated evidence.','request_id',gen_random_uuid()));
  reset role;
  set local role service_role;
  insert into public.unsite_candidates(id,space_id,source_version_id,job_id,chunk_index,item_index,kind,title,text,fields,context,evidence,warnings) values
    (candidate_a,sid,(version_a->>'id')::uuid,(select id from public.unsite_jobs where source_version_id=(version_a->>'id')::uuid),0,0,'project','Project Atlas','Atlas has qualified context.','{"owner":"Rae"}',context,'[{"quote":"PRIVATE_EVIDENCE_MARK","locator":"Passage 1"}]','[]'),
    (candidate_b,sid,(version_b->>'id')::uuid,(select id from public.unsite_jobs where source_version_id=(version_b->>'id')::uuid),0,0,'project','Project Atlas','Atlas has updated context.','{"owner":"Morgan"}',context,'[{"quote":"PRIVATE_EVIDENCE_MARK","locator":"Passage 1"}]','[]');
  insert into public.unsite_memberships(space_id,user_id,role) values(sid,viewer_uid,'viewer');
  reset role;
  set local role authenticated;
  snap:=public.unsite_compare_candidate(candidate_a);
  assert jsonb_array_length(snap)=2,'comparison includes local approved entry and proposed source';
  assert not snap::text like '%OTHER_TENANT_PRIVATE%','comparisons exclude another tenant';
  perform public.unsite_command('review_candidate',jsonb_build_object('space_id',sid,'candidate_id',candidate_a,'revision',1,'decision','accept','record_id',entry_id,'record_revision',1,'kind','project','title','Project Atlas','text','Atlas has qualified context.','fields','{"launch_date":null,"owner":"Rae"}'::jsonb,'context',context));
  denied:=false;begin
    perform public.unsite_command('review_candidate',jsonb_build_object('space_id',sid,'candidate_id',candidate_b,'revision',1,'decision','accept','record_id',entry_id,'record_revision',1,'kind','project','title','Project Atlas','text','Stale overwrite.','fields','{}'::jsonb));
  exception when raise_exception then denied:=SQLERRM='Record changed';end;assert denied,'review cannot overwrite a newer entry';
  perform public.unsite_command('review_candidate',jsonb_build_object('space_id',sid,'candidate_id',candidate_b,'revision',1,'decision','accept','record_id',entry_id,'record_revision',2,'kind','project','title','Project Atlas','text','Atlas has updated and qualified context.','fields','{"launch_date":null,"owner":"Rae"}'::jsonb,'context',context));
  assert (select count(*) from public.unsite_record_evidence where record_id=entry_id)=2,'both source versions remain in evidence history';
  snap:=public.unsite_knowledge_snapshot(sid);
  assert snap->'snapshot'->>'schema_version'='2.1','linked publication schema';
  assert (select value->'fields'->'launch_date'='null'::jsonb from jsonb_array_elements(snap->'snapshot'->'records') where value->>'id'=entry_id::text),'unknown fields remain explicit';
  assert (select jsonb_array_length(value->'links')=1 from jsonb_array_elements(snap->'snapshot'->'records') where value->>'id'=entry_id::text),'approved relationships included';
  assert not (snap::text like '%PRIVATE_EVIDENCE_MARK%' or snap::text like '%PRIVATE_ORIGINAL_MARK%'),'public projection excludes private evidence';
  release:=public.unsite_command('publish_release',jsonb_build_object('space_id',sid,'revision',snap->>'source_revision','reviewed',true,'request_id',gen_random_uuid()));
  assert (select data from public.unsite_releases where id=(release->>'id')::uuid)=snap->'snapshot','publication exactly matches approved preview';
  perform public.unsite_command('edit_record',jsonb_build_object('space_id',sid,'record_id',target_id,'revision',1,'title','Rae','kind','person','text','Excluded draft','fields','{}'::jsonb,'active',false));
  snap:=public.unsite_knowledge_snapshot(sid);
  assert jsonb_array_length(snap->'snapshot'->'records')=1,'excluded records are omitted';
  assert jsonb_array_length(snap->'snapshot'->'records'->0->'links')=0,'relationships do not reveal excluded records';
  denied:=false;begin
    perform public.unsite_command('publish_release',jsonb_build_object('space_id',sid,'revision',release->>'source_revision','reviewed',true,'request_id',gen_random_uuid()));
  exception when raise_exception then denied:=SQLERRM='Record changed';end;assert denied,'stale preview cannot publish changed knowledge';
  second_release:=public.unsite_command('publish_release',jsonb_build_object('space_id',sid,'revision',snap->>'source_revision','reviewed',true,'request_id',gen_random_uuid()));
  assert (select jsonb_array_length(data->'records')=2 from public.unsite_releases where id=(release->>'id')::uuid),'old release stays immutable';
  perform set_config('request.jwt.claim.sub',other_uid::text,true);
  assert public.unsite_knowledge_snapshot(sid) is null,'snapshot tenant isolation';
  assert public.unsite_compare_candidate(candidate_a)='[]'::jsonb,'comparison tenant isolation';
  assert (select count(*) from public.unsite_record_evidence where space_id=sid)=0,'evidence tenant isolation';
  assert (select count(*) from public.unsite_record_links where space_id=sid)=0,'relationship tenant isolation';
  assert (select count(*) from public.unsite_retrieval_cases where space_id=sid)=0,'saved questions tenant isolation';
  perform set_config('request.jwt.claim.sub',viewer_uid::text,true);
  assert public.unsite_knowledge_snapshot(sid) is not null,'viewer may inspect approved knowledge';
  denied:=false;begin
    perform public.unsite_retrieval_case_command('delete_retrieval_case',jsonb_build_object('space_id',sid,'case_id',case_row->>'id'));
  exception when insufficient_privilege then denied:=true;end;assert denied,'viewer cannot modify tests';
  reset role;
  set local role anon;
  denied:=false;begin perform public.unsite_knowledge_snapshot(sid);exception when insufficient_privilege then denied:=true;end;assert denied,'anonymous clients cannot read draft snapshots';
  denied:=false;begin perform 1 from public.unsite_record_evidence;exception when insufficient_privilege then denied:=true;end;assert denied,'anonymous clients cannot read evidence';
  reset role;
end $$;
rollback;
select 'PASS: linked knowledge, private comparisons, evidence lineage, exact publication previews, relationship isolation, atomic writes, unknown values, version fencing and bounded private retrieval cases' as result;
