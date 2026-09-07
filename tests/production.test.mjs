import {test} from "node:test";
import assert from "node:assert/strict";
import {createRequire} from "node:module";
import {fileURLToPath} from "node:url";
import {randomUUID} from "node:crypto";
const root=fileURLToPath(new URL("..",import.meta.url)).replace(/\/$/,"");
const {build}=createRequire(root+"/package.json")("esbuild");
globalThis.__UNSITE_PRODUCTION_TEST_ENV__={UNSITE_SUPABASE_URL:"https://supabase.example.invalid",UNSITE_SUPABASE_PUBLISHABLE_KEY:"sb_publishable_test",UNSITE_APP_ORIGIN:"https://unsite.example.invalid"};
const compiled=await build({stdin:{contents:`
export * from ${JSON.stringify(root+"/supabase/functions/unsite-worker/prepare.ts")};
export * from ${JSON.stringify(root+"/supabase/functions/unsite-worker/processing.ts")};
export * from ${JSON.stringify(root+"/supabase/functions/unsite-worker/crawler.ts")};
export * from ${JSON.stringify(root+"/lib/production/release.ts")};
export * from ${JSON.stringify(root+"/lib/production/invitations.ts")};
export {commandSchemas} from ${JSON.stringify(root+"/lib/production/contracts.ts")};
export {deliverV2} from ${JSON.stringify(root+"/supabase/functions/unsite/v2.ts")};
export {GET as appGet,POST as appPost} from ${JSON.stringify(root+"/app/api/app/[...path]/route.ts")};
export {GET as authGet,POST as authPost} from ${JSON.stringify(root+"/app/api/auth/route.ts")};
`,loader:"ts",resolveDir:root},bundle:true,format:"esm",platform:"node",write:false,tsconfig:root+"/tsconfig.json",logLevel:"silent",plugins:[{name:"worker-env",setup(b){b.onResolve({filter:/^(cloudflare:workers|\.\/runtime-env)$/},()=>({path:"env",namespace:"test"}));b.onLoad({filter:/.*/,namespace:"test"},()=>({contents:"export const env=globalThis.__UNSITE_PRODUCTION_TEST_ENV__",loader:"js"}));}}]});
const m=await import("data:text/javascript;base64,"+Buffer.from(compiled.outputFiles[0].text).toString("base64"));
const id=randomUUID(),version=randomUUID(),record=randomUUID();
const passage="Our public studio is based in Melbourne. We offer design services by appointment.";
const candidate={kind:"location",title:"Studio",text:"The studio is based in Melbourne.",fields:[{key:"city",value:"Melbourne"}],quotes:["Our public studio is based in Melbourne."],warnings:[]};
test("customer routes require real customer sessions and reject cross-origin writes",async()=>{
  const unauth=await m.appGet(new Request("https://unsite.example.invalid/api/app/spaces"));assert.equal(unauth.status,401);assert.match(unauth.headers.get("Cache-Control"),/no-store/);
  const forged=new Request("https://unsite.example.invalid/api/auth",{method:"POST",headers:{Origin:"https://attacker.example.invalid","Content-Type":"application/json"},body:JSON.stringify({action:"signin",email:"fake@example.invalid",password:"fake"})});assert.equal((await m.authPost(forged)).status,403);
  const session=await m.authGet(new Request("https://unsite.example.invalid/api/auth"));assert.deepEqual(await session.json(),{user:null});
  const fakePlatformHeaders=await m.appGet(new Request("https://unsite.example.invalid/api/app/spaces",{headers:{"oai-authenticated-user-email":"someone@example.invalid","oai-authenticated-user-id":randomUUID()}}));assert.equal(fakePlatformHeaders.status,401,"platform headers must not become customer credentials");
});
test("source and publication contracts enforce file limits and explicit disclosure",()=>{
  assert.equal(m.commandSchemas.source_intake.safeParse({space_id:id,title:"file",kind:"file",mime_type:"application/pdf",byte_size:21*1024*1024,request_id:randomUUID()}).success,false);
  assert.equal(m.commandSchemas.source_intake.safeParse({space_id:id,title:"page",kind:"url",origin_url:"http://example.com",request_id:randomUUID()}).success,false);
  assert.equal(m.commandSchemas.publish_release.safeParse({space_id:id,revision:1,reviewed:false,request_id:randomUUID(),summary:""}).success,false);
  assert.equal(m.commandSchemas.edit_record.safeParse({space_id:id,record_id:record,revision:1,title:"x",text:"y",kind:"general",fields:{},active:true,public_source_url:"javascript:alert(1)"}).success,false);
});

test("workspace control contracts enforce email-bound invites and restrict role choices",()=>{
  const invitation={space_id:id,email:"person@example.invalid",role:"viewer",token:"a".repeat(64),request_id:randomUUID()};
  assert.equal(m.commandSchemas.create_invitation.safeParse(invitation).success,true);
  assert.equal(m.commandSchemas.create_invitation.safeParse({...invitation,role:"owner"}).success,false);
  assert.equal(m.commandSchemas.create_invitation.safeParse({...invitation,token:"short"}).success,false);
  assert.equal(m.commandSchemas.update_member.safeParse({space_id:id,user_id:record,role:"owner"}).success,false);
  assert.equal(m.commandSchemas.restore_source.safeParse({space_id:id,source_id:record}).success,true);
  const next=`/?invite=${record}&token=${"a".repeat(64)}`;
  assert.equal(m.invitationReturnPath(next),next);
  for(const unsafe of ["//evil.invalid", "https://evil.invalid", "/?invite=bad&token=bad", "/account/admin", "/?next=https://evil.invalid"]){assert.equal(m.invitationReturnPath(unsafe),"/");}
});

test("workspace directory, access, exports and account security require a customer session",async()=>{
  for(const path of ["workspace-settings","workspace-export","record-directory","activity"]){assert.equal((await m.appGet(new Request(`https://unsite.example.invalid/api/app/${path}?space=${id}`))).status,401);}
  for(const action of ["change_password","signout_others"]){const response=await m.authPost(new Request("https://unsite.example.invalid/api/auth",{method:"POST",headers:{"Content-Type":"application/json"},body:JSON.stringify({action,current_password:"old-password",password:"new-password-123456"})}));assert.equal(response.status,401);}
  assert.equal((await m.appPost(new Request("https://unsite.example.invalid/api/app/accept_invitation",{method:"POST",headers:{"Content-Type":"application/json"},body:JSON.stringify({invitation_id:record,token:"a".repeat(64)})}))).status,401);
});
test("chunking preserves every character and rejects inaccessible or oversized text",()=>{
  const text=("A long paragraph that remains complete.\n".repeat(1200))+"Final sentence.";
  const pieces=m.chunks(text);assert.equal(pieces.join(""),text);assert.ok(pieces.every(p=>p.length<=12000));assert.ok(pieces.length>1);
  assert.throws(()=>m.chunks(" "),e=>e.code==="NO_TEXT");assert.throws(()=>m.chunks("a".repeat(200001)),e=>e.code==="TEXT_LIMIT");
});
test("preparation requires verbatim evidence and rejects unsafe/malformed fields",()=>{
  const result=m.verifyCandidates({candidates:[candidate]},passage,version,0);assert.equal(result[0].evidence[0].source_version_id,version);assert.deepEqual({...result[0].fields},{city:"Melbourne"});
  assert.throws(()=>m.verifyCandidates({candidates:[{...candidate,quotes:["We have offices in Tokyo and Paris."]}]},passage,version,0),e=>e.code==="UNVERIFIED_EVIDENCE");
  assert.throws(()=>m.verifyCandidates({candidates:[{...candidate,fields:[{key:"__proto__",value:"bad"}]}]},passage,version,0),e=>e.code==="INVALID_FIELDS");
  assert.throws(()=>m.verifyCandidates({candidates:[{...candidate,quotes:[]}]},passage,version,0),e=>e.code==="INVALID_PREPARATION");
});
test("model adapter requests strict structured output with store disabled and never fabricates success",async()=>{
  let request;
  const result=await m.prepare(passage,version,0,{key:"test-only",model:"test-model"},async(url,options)=>{assert.equal(url,"https://api.openai.com/v1/responses");request=JSON.parse(options.body);return Response.json({status:"completed",output:[{content:[{type:"output_text",text:JSON.stringify({candidates:[candidate]})}]}]});});
  assert.equal(result.length,1);assert.equal(request.store,false);assert.equal(request.text.format.strict,true);assert.equal(request.text.format.type,"json_schema");assert.ok(!request.tools);assert.match(request.instructions,/untrusted data/);
  await assert.rejects(m.prepare(passage,version,0,{key:"",model:""}),e=>e.disposition==="blocked");
  await assert.rejects(m.prepare(passage,version,0,{key:"test",model:"test"},async()=>{throw new Error("timeout");}),e=>e.code==="PROVIDER_UNCERTAIN"&&e.disposition==="blocked");
  await assert.rejects(m.prepare(passage,version,0,{key:"test",model:"test"},async()=>new Response(null,{status:429})),e=>e.disposition==="retry");
  await assert.rejects(m.prepare(passage,version,0,{key:"test",model:"test"},async()=>Response.json({status:"incomplete",output:[]})),e=>e.code==="INCOMPLETE_PREPARATION");
});
test("AI approval contract requires explicit consent for this disclosure version",()=>{
  const p={space_id:id,version_id:version,approved:true,disclosure_version:"openai-source-preparation-2026-09-05",request_id:randomUUID()};
  assert.equal(m.commandSchemas.prepare_source.safeParse(p).success,true);
  assert.equal(m.commandSchemas.prepare_source.safeParse({...p,approved:false}).success,false);
  assert.equal(m.commandSchemas.prepare_source.safeParse({...p,disclosure_version:"old"}).success,false);
});
test("worker sends nothing without consent, credentials, or a fresh dispatch authorization",async()=>{
  const job={id:randomUUID(),source_version_id:version,lease_token:randomUUID(),cursor:0};
  for(const reason of ["no-consent","no-key","revoked","stale","duplicate","limit"]){
    const calls=[];let outgoing=0;
    const rest=async(path,body)=>{calls.push({path,body});if(path.startsWith("unsite_ai_authorizations?"))return reason==="no-consent"?[]:[{id:randomUUID()}];if(path==="rpc/unsite_ai_dispatch")return {allowed:false,reason:reason==="stale"?"STALE_LEASE":reason==="duplicate"?"ALREADY_DISPATCHED":reason==="limit"?"AI_DAILY_LIMIT":"AI_APPROVAL_REQUIRED"};return true;};
    await m.prepareAuthorizedJob(job,passage,{key:reason==="no-key"?"":"fixture",model:"fixture-model"},rest,async()=>{outgoing++;throw new Error("must not send");});
    assert.equal(outgoing,0,reason);
    if(reason==="no-consent"||reason==="no-key")assert.ok(!calls.some(c=>c.path==="rpc/unsite_ai_dispatch"),"no reservation without consent and provider configuration");
  }
});
test("authorized worker checkpoints supported suggestions and records actual provider usage",async()=>{
  const job={id:randomUUID(),source_version_id:version,lease_token:randomUUID(),cursor:0},dispatchId=randomUUID(),calls=[];
  const rest=async(path,body)=>{calls.push({path,body});if(path.startsWith("unsite_ai_authorizations?"))return [{id:randomUUID()}];if(path==="rpc/unsite_ai_dispatch")return {allowed:true,dispatch_id:dispatchId};return true;};
  const sent=[];
  await m.prepareAuthorizedJob(job,passage,{key:"fixture",model:"fixture-model"},rest,async(url,options)=>{sent.push(JSON.parse(options.body));return Response.json({id:"response-fixture",status:"completed",usage:{input_tokens:50,output_tokens:60},output:[{content:[{type:"output_text",text:JSON.stringify({candidates:[candidate]})}]}]});});
  assert.equal(sent.length,1);assert.equal(sent[0].store,false);assert.ok(!JSON.stringify(sent[0]).includes("owner_id"));
  const finish=calls.find(c=>c.path==="rpc/unsite_ai_finish").body;assert.equal(finish.p_status,"succeeded");assert.equal(finish.p_input_tokens,50);assert.equal(finish.p_output_tokens,60);
  const checkpoint=calls.find(c=>c.path==="rpc/unsite_job_result").body.result;assert.equal(checkpoint.dispatch_id,dispatchId);assert.equal(checkpoint.candidates[0].evidence[0].source_version_id,version);
});
test("ambiguous provider or checkpoint failures pause instead of automatically charging again",async()=>{
  const job={id:randomUUID(),source_version_id:version,lease_token:randomUUID(),cursor:0};
  for(const failure of ["provider","checkpoint"]){const reports=[];let sends=0;
    const rest=async(path,body)=>{if(path.startsWith("unsite_ai_authorizations?"))return [{id:randomUUID()}];if(path==="rpc/unsite_ai_dispatch")return {allowed:true,dispatch_id:randomUUID()};if(path==="rpc/unsite_job_result"){if(body.result.mode==="chunk")throw new Error("lost checkpoint");reports.push(body.result);}return true;};
    await m.prepareAuthorizedJob(job,passage,{key:"fixture",model:"fixture-model"},rest,async()=>{sends++;if(failure==="provider")throw new Error("connection lost");return Response.json({status:"completed",output:[{content:[{type:"output_text",text:JSON.stringify({candidates:[candidate]})}]}]});});
    assert.equal(sends,1);assert.equal(reports[0].code,"PROVIDER_UNCERTAIN");assert.equal(reports[0].disposition,"blocked");
  }
});
test("crawler blocks private DNS answers, denied robots and internal redirects",async()=>{
  let calls=0;
  await assert.rejects(m.importPage("https://example.com/about",{resolve:async()=>["93.184.216.34","127.0.0.1"],html:s=>s,fetch:async()=>{calls++;throw new Error("must not fetch");}}),e=>e.code==="PRIVATE_ADDRESS");assert.equal(calls,0);
  await assert.rejects(m.importPage("https://example.com/private",{resolve:async()=>["93.184.216.34"],html:s=>s,fetch:async()=>{calls++;return new Response("User-agent: UnsiteBot\nDisallow: /private");}}),e=>e.code==="ROBOTS_DENIED");assert.equal(calls,1);
  const visited=[];await assert.rejects(m.importPage("https://example.com/about",{resolve:async()=>["93.184.216.34"],html:s=>s,fetch:async url=>{visited.push(String(url));return String(url).endsWith("robots.txt")?new Response(null,{status:404}):new Response(null,{status:302,headers:{Location:"https://127.0.0.1/secret"}});}}));assert.equal(visited.length,2);
});
test("release diffs ignore object key ordering and identify added, edited and removed entries",()=>{
  const first={id,records:[{id:record,title:"Studio",kind:"location",text:passage,fields:{city:"Melbourne",country:"Australia"},revision:1}],name:"Studio",kind:"business",description:"",schema_version:"2.0"};
  const identical={...first,records:[{revision:1,fields:{country:"Australia",city:"Melbourne"},text:passage,kind:"location",title:"Studio",id:record}]};assert.equal(m.releaseDiff(first,identical).changed.length,0);
  assert.equal(m.releaseDiff(first,{...first,records:[{...first.records[0],text:"Updated"}]}).changed.length,1);
  assert.equal(m.releaseDiff(first,{...first,records:[]}).removed.length,1);
});
test("v2 delivery uses the active release relationship and supports stable public resources",async()=>{
  const release={id:randomUUID(),space_id:id,revision:4,source_revision:8,published_at:new Date().toISOString(),data:{schema_version:"2.0",id,name:"Public studio",kind:"business",description:"A studio",records:[{id:record,kind:"location",title:"Studio",text:passage,fields:{city:"Melbourne"},revision:1}]}};
  let available=true;
  const rest=async path=>{assert.match(path,/active_release_id=not.is.null/);assert.match(path,/unsite_releases!unsite_active_release/);assert.ok(!path.includes("unsite_source_versions"));return available?[{id,release}]:[];};
  const read=path=>m.deliverV2(new Request("https://api.example.invalid/functions/v1/unsite/v2/"+id+path),["v2",id,...path.split("?")[0].split("/").filter(Boolean)],"https://api.example.invalid",rest);
  let r=await read("/records?q=melbourne");assert.equal(r.status,200);assert.equal((await r.json()).total,1);
  r=await read("/records/"+record+"?format=md");assert.match(await r.text(),/Melbourne/);
  assert.equal((await read("/records?limit=101")).status,400);assert.equal((await read("/source_versions")).status,404);assert.equal((await read("/records/"+randomUUID())).status,404);
  const spec=await (await read("/openapi.json")).json();assert.equal(spec.openapi,"3.1.0");assert.ok(spec.paths["/records/{id}"]);
  r=await m.deliverV2(new Request("https://api.example.invalid/",{method:"HEAD"}),["v2",id,"profile"],"https://api.example.invalid",rest);assert.equal(await r.text(),"");assert.equal(r.headers.get("X-Unsite-Release"),release.id);
  available=false;assert.equal((await read("/bundle.json")).status,404);
});
