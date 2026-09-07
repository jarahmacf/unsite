import {test} from "node:test";
import assert from "node:assert/strict";
import {createRequire} from "node:module";
import {fileURLToPath} from "node:url";
import {randomUUID} from "node:crypto";
const root=fileURLToPath(new URL("..",import.meta.url)).replace(/\/$/,"");
const {build}=createRequire(root+"/package.json")("esbuild");
const modules=["lib/production/knowledge.ts","lib/production/contracts.ts","lib/production/release.ts","lib/production/retrieval.ts","supabase/functions/unsite/v2.ts","supabase/functions/unsite-worker/prepare.ts"];
const compiled=await build({stdin:{contents:modules.map(path=>"export * from "+JSON.stringify(root+"/"+path)+";").join("\n"),loader:"ts",resolveDir:root},bundle:true,format:"esm",platform:"node",write:false,logLevel:"silent"});
const m=await import("data:text/javascript;base64,"+Buffer.from(compiled.outputFiles[0].text).toString("base64"));
const sid=randomUUID(),releaseId=randomUUID(),versionId=randomUUID();
const material=[
  {type:"Fictional scene",framing:"fiction",attribution:"Mira, the narrator",title:"The glass orchard",text:"In the story, Mira remembers an orchard made of glass. The narrator calls its trees memories.",fields:{chapter:2,real_event:false,location:null}},
  {type:"Company policy",framing:"source_claim",attribution:"Orchard Cooperative",title:"Visitor policy",text:"Orchard Cooperative admits visitors only by appointment. Accompanied children can enter free.",fields:{appointment_required:true,child_fee:0,currency:"USD"}},
  {type:"Recipe",framing:"instruction",attribution:"",title:"Preserved pears",text:"Add 2.5 grams of salt to the pears. Seal the jar after cooling. The final yield is not specified.",fields:{salt:2.5,unit:"grams",yield:null}},
  {type:"Research finding",framing:"source_claim",attribution:"Study authors",title:"Recall experiment",text:"The study measured recall after rest. Its sample was small, so broader conclusions remain uncertain.",fields:{sample_size:12}},
  {type:"Essay",framing:"opinion",attribution:"Inez",title:"On forgetting",text:"Inez argues that forgetting can make room for other experiences. This is an essayist's viewpoint.",fields:{}},
];
const records=material.map(x=>({id:randomUUID(),kind:"general",title:x.title,text:x.text,fields:x.fields,context:{...m.emptyContext(),type_label:x.type,framing:x.framing,attribution:x.attribution,summary:x.text,topics:["Memory"]},revision:1,links:[]}));
const snapshot={schema_version:"2.1",id:sid,name:"Mixed archive",kind:"collection",description:"Writing, operations, research and methods",records};
const release={id:releaseId,space_id:sid,revision:1,source_revision:7,published_at:"2026-09-05T12:00:00Z",data:snapshot};
const base="https://api.example.invalid/functions/v1/unsite/v2/"+sid;
const read=(path="",options={})=>m.deliverV2(new Request(base+path,options),["v2",sid,...path.split("?")[0].split("/").filter(Boolean)],"https://api.example.invalid",async()=>[{id:sid,release}]);
const rpc=(method,params)=>read("/mcp",{method:"POST",headers:{"Content-Type":"application/json"},body:JSON.stringify({jsonrpc:"2.0",id:1,method,params})});
const candidates=records.map(r=>({kind:r.kind,title:r.title,text:r.text,fields:Object.entries(r.fields).map(([key,value])=>({key,value})),context:r.context,quotes:[r.text],warnings:[],suggested_links:[]}));
const passage=records.map(r=>r.text).join("\n\n");

test("one collection accepts arbitrary content types, preserves old records, and rejects malformed semantic metadata",()=>{
  assert.equal(m.commandSchemas.create_space.parse({name:"Mixed archive",request_id:randomUUID()}).kind,"collection");
  for(const record of records){
    assert.ok(m.commandSchemas.create_record.safeParse({space_id:sid,title:record.title,kind:record.kind,text:record.text,fields:record.fields,context:record.context,request_id:randomUUID()}).success);
  }
  assert.equal(m.entryType({kind:"project"}),"Project");
  assert.equal(m.entryType({kind:"general",context:{type_label:"  研究ノート  "}}),"研究ノート");
  const context=records[0].context;
  for(const bad of [{type_label:"x".repeat(101)},{type_label:42},{framing:"verified_truth"},{framing:null},{attribution:[]},{attribution:"x".repeat(601)},{secret:"private"}]){
    assert.equal(m.validContext({...context,...bad}),false);
    assert.equal(m.commandSchemas.create_record.safeParse({space_id:sid,title:"Entry",kind:"general",text:"Content",fields:{},context:{...context,...bad},request_id:randomUUID()}).success,false);
  }
  assert.equal(m.validContext({summary:"",aliases:[],topics:[],status:"unspecified",as_of:null}),true);
});

test("mixed preparation retains perspectives and native primitive values, rejecting ambiguous fields and unsupported evidence",()=>{
  const result=m.verifyCandidates({candidates},passage,versionId,0);
  assert.deepEqual(result.map(r=>r.context.framing),["fiction","source_claim","instruction","source_claim","opinion"]);
  assert.equal(result[0].context.attribution,"Mira, the narrator");
  assert.equal(result[0].fields.real_event,false);
  assert.equal(result[1].fields.child_fee,0);
  assert.equal(result[2].fields.salt,2.5);
  assert.equal(result[2].fields.yield,null);
  for(const fields of [
    [{key:"salt",value:2.5},{key:" salt ",value:3}],
    [{key:"value",value:{nested:true}}],
    [{key:"value",value:Infinity}],
    [{key:" constructor ",value:"unsafe"}],
  ])assert.throws(()=>m.verifyCandidates({candidates:[{...candidates[2],fields}]},passage,versionId,0),e=>e.code==="INVALID_FIELDS");
  assert.throws(()=>m.verifyCandidates({candidates:[{...candidates[0],quotes:["The real author lived in the glass orchard."]}]},passage,versionId,0),e=>e.code==="UNVERIFIED_EVIDENCE");
  assert.equal(m.differingFields({fields:{value:null}},{fields:{value:""}}).length,1);
  assert.equal(m.differingFields({fields:{value:2.5}},{fields:{value:"2.5"}}).length,1);
});

test("the provider boundary delivers the supplied passage and accepts mixed structured output without coercion",async()=>{
  let requests=0;
  const result=await m.prepareWithUsage(passage,versionId,0,{key:"fixture-key",model:"fixture-model"},async(url,options)=>{
    requests++;
    const body=JSON.parse(options.body);
    assert.equal(JSON.parse(body.input[0].content[0].text).source_text,passage);
    assert.equal(body.store,false);
    return Response.json({status:"completed",id:"response-fixture",usage:{input_tokens:100,output_tokens:200},output:[{content:[{type:"output_text",text:JSON.stringify({candidates})}]}]});
  });
  assert.equal(requests,1);
  assert.equal(result.candidates.length,5);
  assert.equal(result.candidates[0].fields.real_event,false);
  assert.equal(result.candidates[2].context.type_label,"Recipe");
  assert.equal(result.candidates[4].context.framing,"opinion");
  assert.equal(result.inputTokens,100);
});

test("HTTP discovery and retrieval preserve framing, attribution and complete content in every public representation",async()=>{
  const manifest=await (await read()).json();
  assert.deepEqual(manifest.content_types.map(t=>t.name),["Company policy","Essay","Fictional scene","Recipe","Research finding"]);
  const search=await (await read("/search?q=Mira&type="+encodeURIComponent("  FICTIONAL SCENE  "))).json();
  assert.equal(search.results[0].id,records[0].id);
  assert.equal(search.results[0].context.framing,"fiction");
  assert.equal((await (await read("/search?q=Mira&type=Recipe")).json()).total,0);
  assert.equal(m.searchKnowledge(snapshot,"Inez").results[0].id,records[4].id);
  assert.equal((await (await read("/records?type=recipe")).json()).records[0].fields.yield,null);
  for(const path of ["/index.md","/records/"+records[0].id+"?format=md","/catalog.md?type=Fictional%20scene"]){
    const markdown=await (await read(path)).text();
    assert.ok(markdown.includes("Fiction or imagined scenario"));
    assert.ok(markdown.includes("Perspective: Mira, the narrator"));
    assert.ok(markdown.includes("Fictional scene"));
    assert.ok(!markdown.includes("\\n\\n"),"Markdown separators are actual newlines");
  }
  const md=await (await read("/records/"+records[0].id+"?format=md")).text();
  assert.ok(md.indexOf("Fiction or imagined scenario")<md.indexOf(records[0].text));
  const bundle=await (await read("/bundle.json")).json();
  assert.deepEqual(bundle.records,records);
  assert.equal((await read("/search?q=memory&type="+"x".repeat(101))).status,400);
  assert.equal((await read("/records?type="+"x".repeat(101))).status,400);
  const spec=await (await read("/openapi.json")).json();
  assert.ok(spec.paths["/search"].get.parameters.some(p=>p.name==="type"));
  assert.ok(spec.paths["/records"].get.responses["200"].content["application/json"].schema.properties.records.items.properties.context.properties.framing.enum.includes("fiction"));
});

test("MCP clients can filter flexible types and read the same attributed material",async()=>{
  const tools=await (await rpc("tools/list")).json();
  assert.ok(tools.result.tools[0].inputSchema.properties.type);
  let reply=await (await rpc("tools/call",{name:"search",arguments:{query:"memory",type:"ESSAY"}})).json();
  const result=JSON.parse(reply.result.content[0].text);
  assert.deepEqual(result.results.map(r=>r.id),[records[4].id]);
  reply=await (await rpc("tools/call",{name:"fetch",arguments:{id:records[0].id,release_id:releaseId}})).json();
  const fetched=JSON.parse(reply.result.content[0].text);
  assert.equal(fetched.context.framing,"fiction");
  assert.equal(fetched.fields.real_event,false);
  assert.ok(fetched.text.includes("Perspective: Mira, the narrator"));
  reply=await (await rpc("resources/read",{uri:base+"/records/"+records[0].id+"?format=md&release="+releaseId})).json();
  assert.ok(reply.result.contents[0].text.includes("Fiction or imagined scenario"));
  reply=await (await rpc("tools/call",{name:"search",arguments:{query:"memory",type:42}})).json();
  assert.equal(reply.error.code,-32602);
});

test("perspective changes appear in release review, and fictional or procedural material is not marked stale for lacking fact dates",()=>{
  const next=structuredClone(snapshot);
  next.records[0].context.attribution="A different narrator";
  assert.deepEqual(m.releaseDiff(snapshot,next).changed.map(r=>r.id),[records[0].id]);
  const missingDates=m.inspectKnowledge(snapshot).checks.find(c=>c.id==="dates").record_ids;
  assert.deepEqual(missingDates,[records[1].id,records[3].id]);
  assert.equal(snapshot.records[0].context.as_of,null);
});

test("combining different material preserves both perspectives without declaring fiction to be a source claim",()=>{
  const combined=m.combineMaterial(records[1],records[0]);
  assert.equal(combined.context.framing,"mixed");
  assert.equal(combined.context.type_label,"Mixed material");
  assert.equal(combined.context.as_of,null);
  assert.ok(combined.text.includes("Perspective: Orchard Cooperative"));
  assert.ok(combined.text.includes("Perspective: Mira, the narrator"));
  assert.ok(combined.text.includes("Source-reported information"));
  assert.ok(combined.text.includes("Fiction or imagined scenario"));
  assert.ok(combined.text.includes(records[0].text));
  assert.ok(combined.text.includes(records[1].text));
  assert.ok(m.validContext(combined.context));
  assert.equal(combined.context.summary,"","a combined summary is an owner review decision");
});
