import {test} from "node:test";
import assert from "node:assert/strict";
import {createRequire} from "node:module";
import {fileURLToPath} from "node:url";
import {randomUUID} from "node:crypto";
const root=fileURLToPath(new URL("..",import.meta.url)).replace(/\/$/,"");
const {build}=createRequire(root+"/package.json")("esbuild");
const paths=["supabase/functions/unsite/api.ts","lib/production/release.ts","lib/production/presence.ts","lib/production/collection.ts","lib/production/retrieval.ts","lib/production/knowledge.ts","lib/production/delivery-check.ts","supabase/functions/unsite-worker/maintenance.ts"];
const compiled=await build({stdin:{contents:paths.map(p=>"export * from "+JSON.stringify(root+"/"+p)+";").join("\n"),resolveDir:root,loader:"ts"},bundle:true,format:"esm",platform:"node",write:false,logLevel:"silent"});
const m=await import("data:text/javascript;base64,"+Buffer.from(compiled.outputFiles[0].text).toString("base64"));
const sid=randomUUID(),rid=randomUUID(),releaseId=randomUUID(),base="https://db.example.invalid/functions/v1/unsite/v2/"+sid;
const record={id:rid,title:"Refund policies",text:"Reimbursements are available for 30 days, except for custom orders.",kind:"policy",revision:1,fields:{days:30},context:m.emptyContext(),links:[]};
const data={schema_version:"2.1",id:sid,name:"Fixture publisher",kind:"business",description:"Approved information",publisher:{...m.emptyPublisher(),official_url:"https://official.example.invalid/"},resources:[{id:randomUUID(),title:"API guide",description:"Read the service definition",url:"https://official.example.invalid/api.json",mime_type:"application/json",revision:1,version_label:"v1",as_of:"2026-09-01"}],records:[record]};
function fixture(){
  let active=true,allowed=true,changed=false;const calls=[];
  const release={id:releaseId,space_id:sid,revision:1,source_revision:1,published_at:"2026-09-01T00:00:00Z",record_count:1,authority:null,data:{...data,records:[]}};
  const handler=m.createHandler({url:"https://db.example.invalid",key:"sb_secret_test",indexed:true,publicOrigin:"https://unsite.example.invalid"},async(url,options)=>{
    const name=new URL(url).pathname.split("/").pop(),p=JSON.parse(options?.body||"{}");calls.push({name,p});
    if(name==="unsite_public_read_budget")return Response.json(allowed);
    if(name==="unsite_public_metadata")return Response.json(active?release:null);
    if(name==="unsite_public_records")return Response.json(!active?null:changed?{changed:true}:{release_id:releaseId,total:p.record_id&&p.record_id!==rid?0:1,records:p.record_id&&p.record_id!==rid?[]:[record]});
    if(name==="unsite_public_directory")return Response.json({total:active?1:0,items:active?[{id:sid,name:data.name}]:[]});
    if(name==="unsite_public_sitemap")return Response.json({total:active?2:0,items:active?[{path:"/p/"+sid,published_at:release.published_at},{path:"/p/"+sid+"/records/"+rid,published_at:release.published_at}]:[]});
    throw new Error("Unexpected storage access: "+name);
  });
  const fetcher=(url,options)=>handler(new Request(url,options));
  return {handler,fetcher,calls,setActive:v=>active=v,setAllowed:v=>allowed=v,setChanged:v=>changed=v};
}
test("indexed API reads a single approved record without loading release history",async()=>{
  const f=fixture(),response=await f.handler(new Request(base+"/records/"+rid)),body=await response.json();
  assert.equal(response.status,200);assert.equal(body.text,record.text);assert.equal(body.release_id,releaseId);
  assert.equal(f.calls.filter(c=>c.name==="unsite_public_records").length,1);assert.equal(f.calls.at(-1).p.record_id,rid);
  assert.match(response.headers.get("Link"),new RegExp("/records/"+rid));assert.ok(response.headers.get("ETag"));
});
test("conditional responses check current public access before returning 304",async()=>{
  const f=fixture(),first=await f.handler(new Request(base+"/profile")),etag=first.headers.get("ETag");
  assert.equal((await f.handler(new Request(base+"/profile",{headers:{"If-None-Match":etag}}))).status,304);
  f.setActive(false);assert.equal((await f.handler(new Request(base+"/profile",{headers:{"If-None-Match":etag}}))).status,404);
});
test("release changes, quotas, unknown resources and HEAD responses stay bounded",async()=>{
  const f=fixture();assert.equal((await f.handler(new Request(base+"/search?q=refunds&release="+randomUUID()))).status,409);
  assert.equal((await f.handler(new Request(base+"/not-an-endpoint"))).status,404);
  f.setChanged(true);assert.equal((await f.handler(new Request(base+"/records"))).status,409);f.setChanged(false);
  assert.equal(await(await f.handler(new Request(base+"/resources",{method:"HEAD"}))).text(),"");
  f.setAllowed(false);const limited=await f.handler(new Request(base+"/records"));assert.equal(limited.status,429);assert.equal(limited.headers.get("Retry-After"),"60");
});
test("resource catalog is available through JSON, Markdown, discovery and MCP",async()=>{
  const f=fixture();assert.equal((await(await f.handler(new Request(base+"/resources"))).json()).resources[0].url,data.resources[0].url);
  const schema=await(await f.handler(new Request(base+"/openapi.json"))).json();assert.ok(schema.paths["/authority"]&&schema.paths["/resources"]);
  assert.match(await(await f.handler(new Request(base+"/index.md"))).text(),/API guide/);
  assert.match(await(await f.handler(new Request(base+"/llms.txt"))).text(),/Canonical publication/);
  const response=await f.handler(new Request(base+"/mcp",{method:"POST",headers:{"Content-Type":"application/json"},body:JSON.stringify({jsonrpc:"2.0",id:1,method:"tools/call",params:{name:"list_resources",arguments:{release_id:releaseId}}})}));
  const message=await response.json();assert.equal(JSON.parse(message.result.content[0].text).resources[0].url,data.resources[0].url);
});
test("delivery checker exercises actual HTTP and MCP contracts without an AI call",async()=>{
  const f=fixture(),report=await m.checkDelivery(base,releaseId,f.fetcher);assert.equal(report.passed,true);assert.equal(report.mode,"direct_http_mcp");assert.equal(report.checks.length,6);
  f.setActive(false);assert.equal((await m.checkDelivery(base,releaseId,f.fetcher)).passed,false);
});
test("identity validation rejects credentials and private domains and cannot claim verification",()=>{
  for(const domain of ["localhost","https://10.0.0.1","https://example.com/path","https://user:pass@example.com"]){assert.equal(m.presenceCommands.claim_domain.safeParse({space_id:sid,domain,request_id:randomUUID()}).success,false);}
  const parsed=m.presenceCommands.claim_domain.parse({space_id:sid,domain:"EXAMPLE.COM",request_id:randomUUID(),verified:true});assert.equal(parsed.domain,"example.com");assert.equal(parsed.verified,undefined);
  assert.equal(m.claimState({status:"verified",expires_at:"2020-01-01"}),"expired");
  assert.equal(m.releaseDiff(data,{...data,resources:[]}).resourcesChanged,true);
});
test("DNS verification accepts only the exact scoped challenge and handles split TXT strings",async()=>{
  const task={kind:"domain",id:randomUUID(),space_id:sid,lease:randomUUID(),domain:"example.com",challenge:"a".repeat(64)},saved=[];
  const rest=async(name,p)=>name.endsWith("unsite_claim_maintenance")?task:saved.push(p);
  const deps={resolve:async()=>[],html:s=>s,fetch:async()=>{throw Error("Unexpected network fetch");},txt:async host=>{assert.equal(host,"_unsite.example.com");return [["unsite="+sid+".",task.challenge]];}};
  await m.runMaintenanceStep(rest,deps);assert.equal(saved[0].p_result.verified,true);assert.equal(saved[0].p_lease,task.lease);
  saved.length=0;await m.runMaintenanceStep(rest,{...deps,txt:async()=>[["unsite="+randomUUID()+"."+task.challenge]]});assert.equal(saved[0].p_result.verified,false);
});
test("GEO metrics distinguish this publication's citations, connected clients and stale answers",()=>{
  const own="https://unsite.example.invalid/p/"+sid;
  const item={question:"Question",platform:"ChatGPT",mode:"web",preferred_source:null,correct:null,stale_answer:null,cited_urls:[]};
  const result=m.visibilitySummary([{...item,cited_urls:[own+"/records/"+rid],correct:true},{...item,cited_urls:["https://elsewhere.example.invalid"],stale_answer:true},{...item,mode:"mcp",cited_urls:[own]},{...item,cited_urls:[own+"-spoof"]}],[own]);
  assert.equal(result.observations,3);assert.equal(result.cited,1);assert.equal(result.correct,1);assert.equal(result.stale,1);assert.equal(result.staleness_reviewed,1);
});
test("retrieval keeps numbers and exceptions, handles basic paraphrases, and reports absent answers",()=>{
  for(const query of ["refund policy","reimbursement","refunds 30 days"]){const result=m.searchKnowledge(data,query);assert.equal(result.results[0].id,rid);assert.match(result.results[0].excerpt,/except for custom orders/);}
  assert.equal(m.searchKnowledge(data,"Neptune satellites").matched,false);
  assert.equal(m.searchKnowledge(data,"reimbursing",{indexedMatches:true}).results[0].id,rid,"a match from Postgres stemming is not discarded by the local excerpt scorer");
});
test("update planning uses source provenance and full content beyond titles, with more than four comparisons",()=>{
  const source=randomUUID(),segment={id:randomUUID(),space_id:sid,source_id:source,source_version_id:randomUUID(),ordinal:0,start_char:0,end_char:40,text:record.text,locator:"Passage"};
  const item={...record,id:randomUUID(),title:"New terms",evidence:[{segment_id:segment.id,source_version_id:segment.source_version_id,quote:record.text,locator:"Passage"}],warnings:[],suggested_links:[]};
  const old=Array.from({length:7},(_,i)=>({...record,id:randomUUID(),title:"Different heading "+i,source_ids:[source]}));
  const plans=m.planCollection([item],[segment],old);assert.equal(plans[0].record_ids.length,7);
  const huge=old.map(r=>({...r,text:record.text+" x".repeat(16000)}));const bounded=m.planCollection([item],[segment],huge);assert.ok(bounded[0].omitted_record_ids.length>0);assert.equal(bounded[0].record_ids.length+bounded[0].omitted_record_ids.length,7);
});
