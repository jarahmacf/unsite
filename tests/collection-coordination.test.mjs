import {test} from "node:test";
import assert from "node:assert/strict";
import {createRequire} from "node:module";
import {fileURLToPath} from "node:url";
import {randomUUID} from "node:crypto";
const root=fileURLToPath(new URL("..",import.meta.url)).replace(/\/$/,"");
const {build}=createRequire(root+"/package.json")("esbuild");
const paths=["lib/production/collection.ts","lib/production/knowledge.ts","lib/production/contracts.ts","supabase/functions/unsite-worker/collection.ts"];
const compiled=await build({stdin:{contents:paths.map(p=>"export * from "+JSON.stringify(root+"/"+p)+";").join("\n"),loader:"ts",resolveDir:root},bundle:true,platform:"node",format:"esm",write:false,logLevel:"silent"});
const m=await import("data:text/javascript;base64,"+Buffer.from(compiled.outputFiles[0].text).toString("base64"));
const sid=randomUUID(),runId=randomUUID(),author="In this story Mira remembers an orchard made of glass. The narrator speaks of imaginary trees.",business="The Orchard Cooperative admits visitors only by appointment. Accompanied children enter free.";
function segment(text,ordinal=0){return {id:randomUUID(),space_id:sid,source_version_id:randomUUID(),ordinal,start_char:ordinal*12000,end_char:ordinal*12000+text.length,text,locator:"Characters 1–"+text.length};}
const segments=[segment(author),segment(business)];
function item(s,title,framing){return {id:randomUUID()+":0",kind:"general",title,text:s.text,fields:{sample:false,fee:0,unknown:null},context:{...m.emptyContext(),type_label:framing==="fiction"?"Fictional scene":"Visitor policy",framing,attribution:framing==="fiction"?"Mira, the narrator":"Orchard Cooperative",topics:["Orchard"]},warnings:[],suggested_links:[],evidence:[{segment_id:s.id,source_version_id:s.source_version_id,quote:s.text,locator:s.locator}]};}
const items=[item(segments[0],"Glass orchard","fiction"),item(segments[1],"Orchard visits","source_claim")];
const records=[{...items[1],id:randomUUID(),revision:7,links:[]}];
function proposal(i){return {kind:i.kind,title:i.title,text:i.text,fields:Object.entries(i.fields).map(([key,value])=>({key,value})),context:i.context,warnings:[],suggested_links:[],source_items:[i.id],evidence:i.evidence.map(e=>({segment_id:e.segment_id,quote:e.quote})),target_record_id:null,change_reason:"Preserve this source's distinct perspective."};}
const raw=()=>({proposals:items.map(proposal),unresolved:[],summary:"The imagined orchard and the cooperative remain separate."});
const response=raw=>Response.json({status:"completed",id:"fixture-response",usage:{input_tokens:120,output_tokens:240},output:[{content:[{type:"output_text",text:JSON.stringify(raw)}]}]});

test("collection approval is explicit and broader than individual source preparation",()=>{
  const p={space_id:sid,goal:"Organize this mixed material",version_ids:segments.map(s=>s.source_version_id),max_requests:40,approved:true,disclosure_version:m.COLLECTION_DISCLOSURE_VERSION,request_id:randomUUID()};
  assert.ok(m.commandSchemas.start_collection_run.safeParse(p).success);
  for(const patch of [{approved:false},{disclosure_version:"openai-source-preparation-2026-09-05"},{version_ids:[]},{version_ids:Array(9).fill(segments[0].source_version_id)},{max_requests:201}])assert.equal(m.commandSchemas.start_collection_run.safeParse({...p,...patch}).success,false);
  assert.equal(m.commandSchemas.resume_collection_run.safeParse({space_id:sid,run_id:runId,max_requests:60,retry_reviewed:false}).success,false);
});

test("bounded planning covers all source items, preserves full text, and routes related material across sources",()=>{
  const plans=m.planCollection(items,segments,records);
  assert.equal(plans.length,1);assert.equal(plans[0].source_items.length,2);assert.deepEqual(plans[0].record_ids,[records[0].id]);
  const many=Array.from({length:43},(_,i)=>({...items[i%2],id:randomUUID()+":0"}));
  const grouped=m.planCollection(many,segments,records);assert.equal(grouped.length,3);assert.ok(grouped.every(b=>b.source_items.length<=20));
  m.assertCoverage(many.map(i=>i.id),grouped.flatMap(b=>b.source_items));
  const large={...items[0],id:randomUUID(),text:"x".repeat(90001)};
  assert.throws(()=>m.planCollection([large],segments,records),/too large/);
  assert.throws(()=>m.planCollection([items[0],items[0]],segments,records),/Repeated/);
});

test("curation preserves fiction, attribution, primitive fields and exact versioned evidence",()=>{
  const result=m.validateCuration(raw(),items,segments,records);
  assert.equal(result.proposals[0].context.framing,"fiction");assert.equal(result.proposals[0].context.attribution,"Mira, the narrator");
  assert.deepEqual({...result.proposals[1].fields},{sample:false,fee:0,unknown:null});
  assert.equal(result.proposals[0].evidence[0].source_version_id,segments[0].source_version_id);
  assert.equal(result.proposals[0].evidence[0].locator,segments[0].locator);
  assert.equal(result.proposals[0].text,author);
});

test("curation rejects silent omission, invented items, forged evidence and unknown update targets",()=>{
  for(const change of [
    r=>r.proposals.pop(),
    r=>r.proposals[0].source_items.push("invented"),
    r=>r.proposals[0].evidence[0].segment_id=randomUUID(),
    r=>r.proposals[0].evidence[0].quote="The actual writer lived in a glass orchard.",
    r=>r.proposals[0].target_record_id=randomUUID(),
    r=>r.proposals[0].fields.push({key:"sample",value:"duplicate"}),
  ]){const r=raw();change(r);assert.throws(()=>m.validateCuration(r,items,segments,records));}
  const r=raw();r.proposals.pop();r.unresolved=[{source_item_id:items[1].id,reason:"The source describes a different real entity; keep it separate until reviewed."}];
  assert.equal(m.validateCuration(r,items,segments,records).unresolved.length,1);
  assert.throws(()=>m.assertEvidence([{...items[0].evidence[0],source_version_id:segments[1].source_version_id}],segments));
});

test("updates carry the frozen approved revision and verifier concerns remain explicit",()=>{
  const r=raw();r.proposals[1].target_record_id=records[0].id;const result=m.validateCuration(r,items,segments,records);
  assert.equal(result.proposals[1].suggested_record_revision,7);
  const v=m.validateVerdicts({verdicts:[{proposal_index:0,verdict:"supported",issues:[]},{proposal_index:1,verdict:"needs_review",issues:["Confirm whether appointment terms still apply."]}]},2);
  assert.equal(v.verdicts[1].verdict,"needs_review");
  assert.throws(()=>m.validateVerdicts({verdicts:[{proposal_index:1,verdict:"supported",issues:[]}]},2));
  assert.throws(()=>m.validateVerdicts({verdicts:[{proposal_index:0,verdict:"unsupported",issues:[]}]},1));
});

function harness(stage,dispatch={allowed:true,dispatch_id:randomUUID()}){
  const input=stage==="extract"?{segment_id:segments[0].id}:{source_items:items.map(i=>i.id),record_ids:records.map(r=>r.id),...(stage==="verify"?{curate_task_id:randomUUID()}:{})};
  const task={id:randomUUID(),space_id:sid,run_id:runId,stage,input,lease_token:randomUUID()};
  const context={run:{goal:"Understand the orchard material",knowledge_snapshot:{records}},segments,extractions:items.map(i=>({id:i.id.split(":")[0],output:{candidates:[i]}})),curated:stage==="verify"?m.validateCuration(raw(),items,segments,records):null};
  const calls=[];
  const rest=async(path,body)=>{calls.push({path,body});if(path.endsWith("claim_collection_task"))return task;if(path.endsWith("collection_context"))return context;if(path.endsWith("collection_dispatch"))return dispatch;return true;};
  return {rest,calls,task};
}

test("source reader, curator and verifier make bounded provider requests only after dispatch authorization",async()=>{
  for(const stage of ["extract","curate","verify"]){const h=harness(stage);let sent=0;
    await m.runCollectionStep(h.rest,{key:"fixture-key",model:"fixture-model"},async(url,options)=>{
      sent++;assert.ok(h.calls.some(c=>c.path.endsWith("collection_dispatch")));
      const b=JSON.parse(options.body);assert.equal(b.store,false);assert.equal(b.model,"fixture-model");
      const input=JSON.parse(b.input[0].content[0].text);
      if(stage==="extract")return response({candidates:[{...proposal(items[0]),quotes:[author]}]});
      assert.deepEqual(input.canonical_segments,segments);assert.equal(input.approved_records[0].revision,7);
      if(stage==="curate")return response(raw());
      assert.equal(input.proposals[0].context.framing,"fiction");return response({verdicts:items.map((_,i)=>({proposal_index:i,verdict:"supported",issues:[]}))});
    });
    assert.equal(sent,1);const checkpoints=h.calls.filter(c=>c.path.endsWith("collection_result"));assert.equal(checkpoints.length,1);assert.equal(checkpoints[0].body.result.mode,"complete");
    assert.ok(h.calls.some(c=>c.path.endsWith("collection_finish")&&c.body.p_input_tokens===120));
  }
});

test("missing credentials, revoked leases and exhausted budgets make no model calls",async()=>{
  for(const [config,dispatch,expected] of [[{key:"",model:"fixture"},{allowed:true},"MODEL_NOT_CONFIGURED"],[{key:"fixture",model:"fixture"},{allowed:false,reason:"RUN_REQUEST_LIMIT"},"RUN_REQUEST_LIMIT"],[{key:"fixture",model:"fixture"},{allowed:false,reason:"STALE_LEASE"},null]]){
    const h=harness("curate",dispatch);await m.runCollectionStep(h.rest,config,async()=>{throw new Error("Must not call the model");});
    const checkpoint=h.calls.find(c=>c.path.endsWith("collection_result"));if(expected)assert.equal(checkpoint.body.result.code,expected);else assert.equal(checkpoint,undefined);
    if(!config.key)assert.ok(!h.calls.some(c=>c.path.endsWith("collection_dispatch")));
  }
});

test("unknown provider outcomes pause for explicit retry; deterministic planning requires no paid request",async()=>{
  const h=harness("curate");await m.runCollectionStep(h.rest,{key:"fixture",model:"fixture"},async()=>{throw new Error("timeout");});
  assert.equal(h.calls.find(c=>c.path.endsWith("collection_result")).body.result.code,"PROVIDER_UNCERTAIN");
  assert.equal(h.calls.find(c=>c.path.endsWith("collection_finish")).body.p_status,"uncertain");
  const plan=harness("plan");await m.runCollectionStep(plan.rest,{key:"",model:""},async()=>{throw new Error("Must not call the model");});
  assert.ok(!plan.calls.some(c=>c.path.endsWith("collection_dispatch")));assert.equal(plan.calls.at(-1).body.result.output.batches.length,1);
});

test("invalid curation checkpoints retain recorded usage and expose no review proposals",async()=>{
  const h=harness("curate");await m.runCollectionStep(h.rest,{key:"fixture",model:"fixture"},async()=>response({proposals:[],unresolved:[],summary:"Dropped everything"}));
  assert.ok(h.calls.some(c=>c.path.endsWith("collection_finish")&&c.body.p_status==="succeeded"&&c.body.p_output_tokens===240));
  assert.equal(h.calls.at(-1).body.result.mode,"error");assert.equal(h.calls.at(-1).body.result.code,"INVALID_CHECKPOINT");
});
