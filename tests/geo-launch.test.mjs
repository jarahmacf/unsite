import {test} from "node:test";
import assert from "node:assert/strict";
import {createRequire} from "node:module";
import {fileURLToPath} from "node:url";
import {randomUUID} from "node:crypto";
const root=fileURLToPath(new URL("..",import.meta.url)).replace(/\/$/,"");
const {build}=createRequire(root+"/package.json")("esbuild");
const paths=["supabase/functions/unsite/api.ts","lib/production/embeddings.ts","lib/production/host-routing.ts","lib/production/readiness.ts","lib/production/presence.ts","lib/production/knowledge.ts","supabase/functions/unsite-worker/semantic.ts","supabase/functions/unsite-worker/launch.ts"];
const compiled=await build({stdin:{contents:paths.map(p=>"export * from "+JSON.stringify(root+"/"+p)+";").join("\n"),resolveDir:root,loader:"ts"},bundle:true,format:"esm",platform:"node",write:false,logLevel:"silent"});
const m=await import("data:text/javascript;base64,"+Buffer.from(compiled.outputFiles[0].text).toString("base64"));
const sid=randomUUID(),rid=randomUUID(),recordId=randomUUID(),key="fixture-provider-key",base="https://db.example.com/functions/v1/unsite/v2/"+sid;
const record={id:recordId,title:"Arrival",text:"Take the east entrance for deliveries.",kind:"location",revision:1,fields:{entrance:"east"},context:m.emptyContext(),links:[]};
function apiFixture(){
  const calls=[];let ready=true,budget=true;
  const release={id:rid,space_id:sid,revision:1,source_revision:1,published_at:"2026-09-01T00:00:00Z",record_count:1,authority:null,semantic_ready:true,data:{schema_version:"2.1",id:sid,name:"Example",kind:"business",description:"Approved",records:[]}};
  const requestFetch=async(url,options)=>{
    const name=new URL(url).pathname.split("/").pop(),p=JSON.parse(options?.body||"{}");calls.push({url:String(url),name,p});
    if(String(url)==="https://api.openai.com/v1/embeddings")return Response.json({data:[{index:0,embedding:[1,...Array(511).fill(0)]}],usage:{total_tokens:7}});
    if(name==="unsite_public_read_budget")return Response.json(true);
    if(name==="unsite_public_metadata")return Response.json({...release,semantic_ready:ready});
    if(name==="unsite_semantic_query_budget")return Response.json(budget);
    if(name==="unsite_hybrid_records"||name==="unsite_public_records")return Response.json({records:[record],total:1});
    throw new Error("Unexpected storage access "+name);
  };
  return {handler:m.createHandler({url:"https://db.example.com",key:"sb_secret_fixture",indexed:true,embeddingKey:key},requestFetch),calls,ready:v=>ready=v,budget:v=>budget=v};
}
const hybrid=(p)=>new Request(base+"/search",{method:"POST",headers:{"Content-Type":"application/json"},body:JSON.stringify({query:"Where should a courier enter?",...p})});
test("ordinary retrieval never calls an embedding provider; semantic requests require explicit consent and readiness",async()=>{
  const f=apiFixture();assert.equal((await f.handler(new Request(base+"/search?q=entrance"))).status,200);
  assert.equal((await f.handler(hybrid({}))).status,400);
  f.ready(false);assert.equal((await f.handler(hybrid({provider_consent:m.queryConsent}))).status,409);
  assert.equal(f.calls.filter(c=>c.name==="embeddings").length,0);
  f.ready(true);f.budget(false);assert.equal((await f.handler(hybrid({provider_consent:m.queryConsent}))).status,429);
  assert.equal(f.calls.filter(c=>c.name==="embeddings").length,0);
});
test("hybrid retrieval preserves semantic-only results and complete context with release fencing",async()=>{
  const f=apiFixture(),response=await f.handler(hybrid({provider_consent:m.queryConsent})),data=await response.json();
  assert.equal(response.status,200);assert.equal(data.results[0].id,recordId);assert.equal(data.results[0].fields.entrance,"east");assert.equal(data.release_id,rid);assert.match(data.retrieval.method,/hybrid/);
  const provider=f.calls.find(c=>c.name==="embeddings");assert.deepEqual(provider.p.input,["Where should a courier enter?"]);assert.equal(provider.p.dimensions,512);
  assert.equal(f.calls.find(c=>c.name==="unsite_hybrid_records").p.rid,rid);assert.equal(response.headers.get("ETag"),null);
  const wrong=new Request(base+"/search?release="+randomUUID(),{method:"POST",headers:{"Content-Type":"application/json"},body:JSON.stringify({query:"Test",provider_consent:m.queryConsent})});assert.equal((await f.handler(wrong)).status,409);
});
test("MCP exposes a separate consent-bearing semantic tool while lexical search remains available",async()=>{
  const f=apiFixture(),request=(method,params)=>new Request(base+"/mcp",{method:"POST",headers:{"Content-Type":"application/json"},body:JSON.stringify({jsonrpc:"2.0",id:1,method,params})});
  const tools=(await(await f.handler(request("tools/list",{}))).json()).result.tools;
  assert.ok(tools.some(t=>t.name==="search"));assert.ok(tools.find(t=>t.name==="semantic_search").inputSchema.required.includes("provider_consent"));
  assert.ok((await(await f.handler(request("tools/call",{name:"semantic_search",arguments:{query:"courier entrance"}}))).json()).error);
  const response=await(await f.handler(request("tools/call",{name:"semantic_search",arguments:{query:"courier entrance",provider_consent:m.queryConsent}}))).json();assert.equal(JSON.parse(response.result.content[0].text).results[0].id,recordId);
});
test("provider failures are not retried and incomplete vectors cannot mark an index ready",async()=>{
  let calls=0;await assert.rejects(()=>m.embedTexts(["public passage"],key,async()=>{calls++;throw new Error("network interrupted");}),/another provider charge/);assert.equal(calls,1);
  await assert.rejects(()=>m.embedTexts(["public passage"],key,async()=>Response.json({data:[{index:0,embedding:[1,2]}]})),/another provider charge/);
  const reports=[];await m.runEmbeddingStep(async(path,p)=>path==="rpc/unsite_claim_embeddings"?{release_id:rid,lease:randomUUID(),chunks:[{id:randomUUID(),content:"Public passage"}]}:reports.push(p),"",async()=>{throw new Error("must not call");});
  assert.equal(reports[0].p_result.code,"provider_missing");assert.equal(reports[0].p_result.chunks,undefined);
});
const binding={space_id:sid,hostname:"knowledge.example.com",probe_token:"a".repeat(64),routable:true,published:true,release_id:rid,indexnow_key:"b".repeat(64)};
test("host discovery does not reveal the IndexNow key; only its exact verification filename resolves",async()=>{
  const handler=m.createHandler({url:"https://db.example.com",key:"sb_secret_fixture",indexed:true},async()=>Response.json(binding));
  const hostBase="https://db.example.com/functions/v1/unsite/hosts/"+binding.hostname;
  const metadata=await(await handler(new Request(hostBase))).json();assert.equal(metadata.indexnow_key,undefined);
  assert.equal((await handler(new Request(hostBase+"/keys/"+"c".repeat(64)))).status,404);
  assert.equal(await(await handler(new Request(hostBase+"/keys/"+binding.indexnow_key))).text(),binding.indexnow_key);
});
function routeFixture(overrides={}){
  const calls=[];return {calls,fetch:async(url,init)=>{calls.push({url:String(url),headers:new Headers(init?.headers)});return String(url).includes("/keys/")?new Response(binding.indexnow_key):String(url).includes("/hosts/")?Response.json({...binding,...overrides}):Response.json({records:[record],total:1});}};
}
const hostRequest=(path,options={})=>new Request("https://knowledge.example.com"+path,{...options,headers:{host:binding.hostname,...options.headers}});
const cfg={base:"https://db.example.com/functions/v1/unsite",origin:"https://unsite.vercel.app"};
test("custom hostname routing isolates tenants, private routes, and forwarded-host spoofing",async()=>{
  const f=routeFixture();assert.deepEqual(await m.routeHostname(hostRequest("/"),cfg,f.fetch),{rewrite:"/p/"+sid});
  for(const path of ["/account","/api/app/state","/p/"+randomUUID(),"/records/nope"]){assert.equal((await m.routeHostname(hostRequest(path),cfg,f.fetch)).status,404);}
  const normal=new Request("https://unsite.vercel.app/demo",{headers:{host:"unsite.vercel.app","x-forwarded-host":binding.hostname}});assert.equal(await m.routeHostname(normal,cfg,f.fetch),null);
  await m.routeHostname(hostRequest("/api/records",{headers:{Authorization:"Bearer private",Cookie:"private=secret"}}),cfg,f.fetch);
  assert.equal(f.calls.at(-1).headers.has("Authorization"),false);assert.equal(f.calls.at(-1).headers.has("Cookie"),false);
});
test("pending domains expose only connection proof; unpublishing preserves only discovery removal surfaces",async()=>{
  const pending=routeFixture({routable:false});assert.equal((await m.routeHostname(hostRequest("/"),cfg,pending.fetch)).status,404);
  assert.equal((await(await m.routeHostname(hostRequest("/.well-known/unsite-host"),cfg,pending.fetch)).json()).probe_token,binding.probe_token);
  const off=routeFixture({published:false,release_id:null});assert.equal((await m.routeHostname(hostRequest("/api/records"),cfg,off.fetch)).status,404);
  assert.equal(await(await m.routeHostname(hostRequest("/"+binding.indexnow_key+".txt"),cfg,off.fetch)).text(),binding.indexnow_key);
  assert.doesNotMatch(await(await m.routeHostname(hostRequest("/sitemap.xml"),cfg,off.fetch)).text(),/<url>/);
});
test("resource checks reject private destinations and respect crawling rules at redirects",async()=>{
  let calls=0;await assert.rejects(()=>m.checkPublicResource({url:"https://resource.example.com/a",mime_type:"application/json"},{resolve:async()=>["127.0.0.1"],fetch:async()=>{calls++;return new Response();}}),/public addresses/);assert.equal(calls,0);
  const deps={resolve:async host=>host==="private.example.com"?["10.1.2.3"]:["1.1.1.1"],fetch:async url=>String(url).endsWith("robots.txt")?new Response("User-agent: *\nAllow: /"):new Response(null,{status:302,headers:{Location:"https://private.example.com/"}})};
  await assert.rejects(()=>m.checkPublicResource({url:"https://resource.example.com/a",mime_type:"text/html"},deps),/public addresses/);
  await assert.rejects(()=>m.checkPublicResource({url:"https://resource.example.com/a",mime_type:"text/html"},{resolve:async()=>["1.1.1.1"],fetch:async()=>new Response("User-agent: UnsiteBot\nDisallow: /")}),/disallow/);
});
test("resource checks retain only response metadata and report format mismatch",async()=>{
  const methods=[];const r=await m.checkPublicResource({url:"https://resource.example.com/a?version=2",mime_type:"application/json"},{resolve:async()=>["1.1.1.1"],fetch:async(url,init)=>{
    if(String(url).endsWith("robots.txt"))return new Response(null,{status:404});methods.push(init.method);
    return init.method==="HEAD"?new Response(null,{status:405}):new Response("body must not be retained",{status:206,headers:{"Content-Type":"text/plain"}});
  }});assert.deepEqual(methods,["HEAD","GET"]);assert.equal(r.ok,true);assert.match(r.warning,/differs/);assert.equal(r.body,undefined);assert.equal(new URL(r.final_url).search,"?version=2");
});
test("IndexNow submits only approved hostname URLs and never reports acceptance as indexing",async()=>{
  const calls=[],deps={resolve:async()=>["1.1.1.1"],fetch:async(url,init)=>{calls.push({url:String(url),init});return String(url).includes("api.indexnow.org")?new Response(null,{status:202}):new Response(binding.indexnow_key);}};
  const payload={hostname:binding.hostname,key:binding.indexnow_key,urls:["https://"+binding.hostname+"/","https://"+binding.hostname+"/records/"+recordId]};
  await assert.rejects(()=>m.submitIndexNow({...payload,urls:["https://another.example.com/private"]},deps),/limited/);assert.equal(calls.length,0);
  const result=await m.submitIndexNow(payload,deps);assert.equal(result.ok,true);assert.equal(result.state,"validation_pending");assert.equal(result.indexed,null);
  assert.deepEqual(JSON.parse(calls.at(-1).init.body).urlList,payload.urls);
});
test("readiness treats old delivery checks and unverified domains as unfinished",()=>{
  const state={space:{active_release_id:rid},releases:[{id:rid,published_at:"2026-09-01T00:00:00Z"}]};
  const data={publisher:m.emptyPublisher(),claims:[],monitors:[],changes:[],delivery_checks:[{release_id:rid,created_at:"2026-09-01T00:00:00Z",result:{passed:true}}]};
  const checks=m.publicationReadiness(state,data,Date.parse("2026-09-07T00:00:00Z"));assert.equal(checks.find(c=>c.id==="delivery").status,"not_checked");assert.equal(checks.find(c=>c.id==="identity").status,"attention");
});
