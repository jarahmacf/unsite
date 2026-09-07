import {test} from "node:test";
import assert from "node:assert/strict";
import {createRequire} from "node:module";
import {fileURLToPath} from "node:url";
import {randomUUID} from "node:crypto";
const root=fileURLToPath(new URL("..",import.meta.url)).replace(/\/$/,"");
const {build}=createRequire(root+"/package.json")("esbuild");
const modules=["lib/production/knowledge.ts","lib/production/retrieval.ts","lib/production/release.ts","supabase/functions/unsite/v2.ts","supabase/functions/unsite/api.ts","supabase/functions/unsite/mcp.ts","supabase/functions/unsite-worker/prepare.ts"];
const compiled=await build({stdin:{contents:modules.map(path=>"export * from "+JSON.stringify(root+"/"+path)+";").join("\n"),loader:"ts",resolveDir:root},bundle:true,format:"esm",platform:"node",write:false,logLevel:"silent"});
const m=await import("data:text/javascript;base64,"+Buffer.from(compiled.outputFiles[0].text).toString("base64"));
const sid=randomUUID(),atlasId=randomUUID(),ownerId=randomUUID(),releaseId=randomUUID();
const context={summary:"A project studying safe deployments.",aliases:["Northstar"],topics:["Research","Deployment"],status:"uncertain",as_of:"2026-09-01"};
const owner={id:ownerId,kind:"person",title:"Rae",text:"Rae owns the Atlas project. Contact Rae by email.",fields:{email:"rae@example.invalid"},context:{...m.emptyContext(),summary:"Owner of Atlas"},revision:1,links:[]};
const atlas={id:atlasId,kind:"project",title:"Project Atlas",text:"Atlas studies deployment options.\n\nThe launch date has not been decided. The current budget is only a draft estimate.",fields:{launch_date:null,budget:12000},context,revision:3,links:[{target_id:ownerId,relation:"created_by"}]};
const snapshot={schema_version:"2.1",id:sid,name:"Atlas knowledge",description:"Research context for the Atlas project",kind:"project",records:[atlas,owner]};
const release={id:releaseId,space_id:sid,revision:4,source_revision:12,published_at:"2026-09-05T12:00:00.000Z",data:snapshot};
const base="https://api.example.invalid/functions/v1/unsite/v2/"+sid;
let stored=true;
const rest=async path=>{assert.ok(path.startsWith("unsite_spaces?"));assert.ok(path.includes("unsite_releases!unsite_active_release"));assert.ok(!path.includes("unsite_candidates"));return stored?[{id:sid,release}]:[];};
const read=(path="",options={})=>m.deliverV2(new Request(base+path,options),["v2",sid,...path.split("?")[0].split("/").filter(Boolean)],"https://api.example.invalid",rest);
const rpc=(message,headers={})=>read("/mcp",{method:"POST",headers:{"Content-Type":"application/json",Accept:"application/json, text/event-stream",...headers},body:JSON.stringify(message)});
test("context validates dates and explicit unknowns without inferring freshness",()=>{
  assert.equal(m.validContext(context),true);assert.equal(m.validContext(m.emptyContext()),true);
  assert.equal(m.validContext({...context,as_of:"2026-02-30"}),false);
  assert.equal(m.validContext({...context,status:"verified"}),false);
  assert.equal(m.validContext({...context,secret:"private"}),false);
  assert.equal(m.validContext({...context,aliases:Array(21).fill("Alias")}),false);
  assert.equal(m.contextOf(undefined).status,"unspecified");
  assert.deepEqual(m.differingFields({fields:{owner:"Rae",launch_date:null}},{fields:{owner:"Morgan",launch_date:null}}),[{key:"owner",incoming:"Rae",existing:"Morgan"}]);
});
test("preparation carries qualified context and requires exact evidence for proposed relationships",()=>{
  const passage="Project Atlas is owned by Rae. The launch date has not been decided.";
  const item={kind:"project",title:"Project Atlas",text:passage,fields:[],context,suggested_links:[{target_title:"Rae",relation:"created_by",quote:"Project Atlas is owned by Rae."}],quotes:[passage],warnings:[]};
  const prepared=m.verifyCandidates({candidates:[item]},passage,randomUUID(),0)[0];
  assert.equal(prepared.context.status,"uncertain");assert.equal(prepared.suggested_links[0].target_title,"Rae");
  assert.throws(()=>m.verifyCandidates({candidates:[{...item,suggested_links:[{...item.suggested_links[0],quote:"Morgan owns Project Atlas."}]}]},passage,randomUUID(),0));
  assert.throws(()=>m.verifyCandidates({candidates:[{...item,context:{...context,as_of:"2026-02-30"}}]},passage,randomUUID(),0));
});
test("retrieval resolves aliases, respects filters and does not turn substrings into facts",()=>{
  let result=m.searchKnowledge(snapshot,"What is Northstar?",{base,release_id:releaseId});
  assert.equal(result.results[0].id,atlasId);assert.equal(result.results[0].context.status,"uncertain");
  assert.equal(result.results[0].fields.launch_date,null);
  assert.ok(result.results[0].markdown_url.includes("release="+releaseId));
  assert.ok(result.results[0].excerpt.includes("not been decided"));
  assert.equal(m.searchKnowledge(snapshot,"Northstar",{kind:"person"}).total,0);
  assert.equal(m.searchKnowledge(snapshot,"Northstar",{topic:"deployment"}).results[0].id,atlasId);
  assert.equal(m.searchKnowledge(snapshot,"postal mail").total,0,"mail must not match email");
  assert.equal(m.searchKnowledge(snapshot,"the and of").matched,false);
  assert.equal(m.searchKnowledge(snapshot,"underwater archaeology").matched,false);
});
test("saved expectations identify missing knowledge and structural checks never invent dates",()=>{
  const cases=[{id:randomUUID(),question:"Northstar",expected_record_id:atlasId,expectation:"find"},{id:randomUUID(),question:"underwater archaeology",expected_record_id:null,expectation:"no_match"},{id:randomUUID(),question:"Northstar",expected_record_id:randomUUID(),expectation:"find"}];
  assert.deepEqual(m.runRetrievalCases(snapshot,cases).map(r=>r.passed),[true,true,false]);
  const checks=m.inspectKnowledge(snapshot).checks;assert.equal(checks.find(c=>c.id==="dates").status,"attention");assert.deepEqual(checks.find(c=>c.id==="dates").record_ids,[ownerId]);
  assert.match(m.recordMarkdown(atlas,base,releaseId),/launch_date: Unknown/);
  assert.match(m.recordMarkdown(atlas,base,releaseId),/Knowledge status: uncertain/);
  assert.ok(m.recordMarkdown(atlas,base,releaseId).includes(ownerId+"?format=md&release="+releaseId));
});
test("public discovery, search and linked records serve one release; stale followups stop",async()=>{
  const manifest=await (await read()).json();assert.equal(manifest.schema_version,"2.1");assert.equal(manifest.release_id,releaseId);assert.ok(manifest.links.mcp.endsWith("/mcp"));assert.equal(manifest.retrieval.answer_generation,false);
  const search=await (await read("/search?q=Northstar")).json();assert.equal(search.results[0].id,atlasId);assert.equal(search.release_id,releaseId);
  const record=await (await read("/records/"+atlasId)).json();assert.equal(record.fields.launch_date,null);assert.equal(record.links[0].target_id,ownerId);
  const md=await (await read("/records/"+atlasId+"?format=md")).text();assert.ok(md.includes(releaseId));assert.ok(md.includes("not been decided"));assert.ok(md.includes("release="+releaseId));
  assert.equal((await read("/search?q=Northstar&release="+randomUUID())).status,409);
  assert.equal((await read("/bundle.json?release="+randomUUID())).status,409);
  assert.equal((await read("/source_versions")).status,404);assert.equal((await read("/records?limit=101")).status,400);
  assert.equal((await read("/search?q=x")).status,400);assert.equal((await read("/search?q=Atlas&limit=21")).status,400);
  const head=await read("/profile",{method:"HEAD"});assert.equal(await head.text(),"");assert.equal(head.headers.get("X-Unsite-Release"),releaseId);
});
test("catalog pagination preserves the release and OpenAPI describes the callable search",async()=>{
  const catalog=await (await read("/catalog.md?limit=1")).text();assert.ok(catalog.includes(atlasId));assert.ok(catalog.includes("Next entries"));assert.ok(catalog.includes("release="+releaseId));
  const topics=await (await read("/topics")).json();assert.equal(topics.topics.find(t=>t.name==="deployment").record_count,1);
  const spec=await (await read("/openapi.json")).json();assert.equal(spec.openapi,"3.1.0");assert.ok(spec.paths["/search"].get.parameters.find(p=>p.name==="q").required);assert.ok(spec.paths["/search"].get.responses["409"]);assert.equal(spec["x-unsite-mcp"].url,base+"/mcp");
});
test("MCP lifecycle, resource discovery and retrieval interoperate over stateless HTTP",async()=>{
  let result=await (await rpc({jsonrpc:"2.0",id:1,method:"initialize",params:{protocolVersion:"2025-11-25",capabilities:{},clientInfo:{name:"test",version:"1"}}})).json();
  assert.equal(result.result.protocolVersion,"2025-11-25");assert.ok(result.result.capabilities.tools);
  const initialized=await rpc({jsonrpc:"2.0",method:"notifications/initialized"});assert.equal(initialized.status,202);assert.equal(await initialized.text(),"");
  const responseMessage=await rpc({jsonrpc:"2.0",id:44,result:{}});assert.equal(responseMessage.status,202);
  result=await (await rpc({jsonrpc:"2.0",id:2,method:"tools/list"})).json();assert.deepEqual(result.result.tools.map(t=>t.name),["search","fetch","list_resources"]);assert.equal(result.result.tools[0].annotations.readOnlyHint,true);
  result=await (await rpc({jsonrpc:"2.0",id:3,method:"tools/call",params:{name:"search",arguments:{query:"Northstar"}}})).json();
  const found=JSON.parse(result.result.content[0].text);assert.equal(found.results[0].id,atlasId);assert.equal(found.release_id,releaseId);
  result=await (await rpc({jsonrpc:"2.0",id:4,method:"tools/call",params:{name:"fetch",arguments:{id:atlasId,release_id:releaseId}}})).json();
  assert.ok(JSON.parse(result.result.content[0].text).text.includes("not been decided"));
  result=await (await rpc({jsonrpc:"2.0",id:5,method:"resources/list"})).json();const uri=result.result.resources[0].uri;assert.ok(uri.includes("release="+releaseId));
  result=await (await rpc({jsonrpc:"2.0",id:6,method:"resources/read",params:{uri}})).json();assert.ok(result.result.contents[0].text.includes(releaseId));
});
test("MCP rejects browser origins, arbitrary fetches, stale reads, malformed requests and oversized bodies",async()=>{
  assert.equal((await rpc({jsonrpc:"2.0",id:1,method:"ping"},{Origin:"https://evil.example.invalid"})).status,403);
  assert.equal((await rpc({jsonrpc:"2.0",method:"notifications/initialized"},{"MCP-Protocol-Version":"unknown"})).status,400);
  assert.equal((await read("/mcp")).status,405);
  let result=await (await rpc({jsonrpc:"2.0",id:2,method:"resources/read",params:{uri:"https://127.0.0.1/secret"}})).json();assert.equal(result.error.code,-32602);
  result=await (await rpc({jsonrpc:"2.0",id:3,method:"tools/call",params:{name:"fetch",arguments:{id:atlasId,release_id:randomUUID()}}})).json();assert.equal(result.result.isError,true);
  assert.equal((await rpc({jsonrpc:"2.0",id:4,method:"ping",params:{extra:"x".repeat(40000)}})).status,413);
  result=await (await rpc([{jsonrpc:"2.0",id:5,method:"ping"}])).json();assert.equal(result.error.code,-32600);
  result=await (await rpc({jsonrpc:"2.0",id:6,method:"tools/call",params:{name:"fetch",arguments:"bad"}})).json();assert.equal(result.error.code,-32602);
});
test("the deployed API handler routes MCP POSTs without enabling writes on other resources",async()=>{
  const requestFetch=async (url,options)=>{assert.ok(url.startsWith("https://api.example.invalid/rest/v1/unsite_spaces?"));assert.ok(options.headers.apikey);return Response.json([{id:sid,release}]);};
  const handle=m.createHandler({url:"https://api.example.invalid",key:"server-fixture"},requestFetch);
  const reply=await handle(new Request(base+"/mcp",{method:"POST",headers:{"Content-Type":"application/json"},body:JSON.stringify({jsonrpc:"2.0",id:1,method:"ping"})}));assert.deepEqual(await reply.json(),{jsonrpc:"2.0",id:1,result:{}});
  assert.equal((await handle(new Request(base+"/records",{method:"POST",body:"{}"}))).status,405);
});
test("unpublishing removes every public format, including MCP and search",async()=>{
  stored=false;
  try{for(const path of ["","/catalog.md","/bundle.json","/search?q=Atlas","/mcp"])assert.equal((await read(path)).status,404);}finally{stored=true;}
});
