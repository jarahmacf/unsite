import {createRequire} from "node:module";
import {fileURLToPath} from "node:url";
import {readFile,readdir} from "node:fs/promises";
import {randomUUID,createHash} from "node:crypto";
import assert from "node:assert/strict";
import {DatabaseSync} from "node:sqlite";
const root=fileURLToPath(new URL("..",import.meta.url)).replace(/\/$/,"");
const {build}=createRequire(root+"/package.json")("esbuild");
const database=new DatabaseSync(":memory:");
for(const file of (await readdir(root+"/drizzle")).filter(n=>n.endsWith(".sql")).sort())database.exec((await readFile(root+"/drizzle/"+file,"utf8")).replaceAll("--> statement-breakpoint",""));
const token="a".repeat(64),hash=createHash("sha256").update(token).digest("hex");
globalThis.__UNSITE_TEST_ENV__={UNSITE_PUBLIC_API:"https://api.test/functions/v1/unsite",UNSITE_PUBLISH_TOKEN:token,DB:{prepare(sql){let values=[];const statement=database.prepare(sql);return {bind(...v){values=v;return this},async run(){statement.run(...values);return {success:true}},async all(){return {results:statement.all(...values)}},async first(){return statement.get(...values)||null}}}}};
const bundle=await build({stdin:{contents:`
import * as list from "${root}/app/api/workspaces/route.ts";
import * as detail from "${root}/app/api/workspaces/[id]/route.ts";
import * as publishing from "${root}/app/api/workspaces/[id]/publish/route.ts";
export {createHandler,cleanPublication} from "${root}/supabase/functions/unsite/api.ts";
export {publicContent} from "${root}/lib/unsite-types.ts";
export async function privateApi(request){const p=new URL(request.url).pathname.split('/');if(p.length===3)return list[request.method](request);const ctx={params:Promise.resolve({id:p[3]})};return p[4]==='publish'?publishing[request.method](request,ctx):detail.GET(request,ctx);}
`,loader:"ts",resolveDir:root},bundle:true,format:"esm",platform:"node",write:false,tsconfig:root+"/tsconfig.json",logLevel:"silent",plugins:[{name:"env",setup(b){b.onResolve({filter:/^cloudflare:workers$/},()=>({path:"env",namespace:"test"}));b.onLoad({filter:/.*/,namespace:"test"},()=>({contents:"export const env=globalThis.__UNSITE_TEST_ENV__",loader:"js"}));}}]});
const {privateApi,createHandler,cleanPublication,publicContent}=await import("data:text/javascript;base64,"+Buffer.from(bundle.outputFiles[0].text).toString("base64"));
const publications=new Map();let outbound;
const publicApi=createHandler({url:"https://api.test",key:"sb_secret_test"},async(url,options)=>{
  const u=new URL(url);
  assert.equal(options.headers.apikey,"sb_secret_test");assert.ok(!options.headers.Authorization,"Modern keys must not be sent as JWTs");
  if(u.pathname.endsWith("unsite_publishers"))return Response.json(u.searchParams.get("token_hash")==="eq."+hash?[{id:"publisher"}]:[]);
  if(u.pathname.endsWith("rpc/unsite_publish")){
    const p=JSON.parse(options.body),old=publications.get(p.p_id);
    if(old&&(old.owner!==p.p_owner||p.p_expected_revision!==old.revision))return Response.json({error:"conflict"},{status:400});
    const row={id:p.p_id,data:p.p_data,active:p.p_active,revision:(old?.revision||0)+1,published_at:new Date().toISOString(),owner:p.p_owner};publications.set(p.p_id,row);return Response.json({revision:row.revision,published_at:row.published_at});
  }
  assert.equal(u.searchParams.get("active"),"eq.true");
  const row=publications.get(u.searchParams.get("id")?.slice(3));return Response.json(row?.active?[row]:[]);
});
const nativeFetch=globalThis.fetch;
globalThis.fetch=async(url,options)=>{outbound=JSON.parse(options.body);return publicApi(new Request(url,options));};
async function call(path,method="GET",data,identity="a",extra={}){
  const response=await privateApi(new Request("https://private.test/api/workspaces"+path,{method,headers:{"Content-Type":"application/json",...(identity?{"oai-authenticated-user-email":identity+"@example.com"}:{}),...extra},...(data===undefined?{}:{body:JSON.stringify(data)})}));return {status:response.status,body:await response.json()};
}
async function read(path,options={}){return publicApi(new Request("https://api.test/functions/v1/unsite"+path,options));}
try{
  assert.equal((await publicApi(new Request("https://api.test/unsite/health"))).status,200,"Handle Supabase's rewritten path");
  const id=randomUUID(),publicId=randomUUID(),privateId=randomUUID();
  const draft={profile:{name:"A person without a website",kind:"person",description:"A writer.",email:""},entries:[
    {id:publicId,title:"About",type:"about",content:"Reviewed public bio.",included:true,source:{kind:"file",label:"private-file.md",url:"",original:"PRIVATE ORIGINAL MATERIAL"}},
    {id:privateId,title:"Private plans",type:"general",content:"SECRET NOT FOR PUBLICATION",included:false,source:{kind:"text",label:"Private note",url:"",original:"SECRET NOT FOR PUBLICATION"}},
  ]};
  assert.equal((await call("","GET",undefined,"")).status,401);
  assert.equal((await call("","POST",{id,revision:0,draft},"a",{Origin:"https://attacker.test"})).status,403);
  let saved=await call("","POST",{id,revision:0,draft});assert.equal(saved.status,200,JSON.stringify(saved.body));
  assert.equal(saved.body.workspace.revision,1);
  assert.equal((await call("/"+id,"GET",undefined,"b")).status,404);
  assert.equal((await call("","POST",{id,revision:1,draft:{...draft,profile:{...draft.profile,name:"Attacker"}}},"b")).status,409);
  assert.equal((await read("/v1/"+id+"/profile")).status,404,"Saving a draft must not publish");
  assert.equal((await call("/"+id+"/publish","POST",{revision:1,reviewed:false})).status,400);
  assert.equal((await call("/"+id+"/publish","POST",{revision:1,reviewed:true},"b")).status,404);
  const published=await call("/"+id+"/publish","POST",{revision:1,reviewed:true});assert.equal(published.status,200,JSON.stringify(published.body));
  assert.ok(!JSON.stringify(outbound).includes("PRIVATE"));assert.ok(!JSON.stringify(outbound).includes("SECRET"));assert.ok(!JSON.stringify(outbound).includes("private-file"));
  const live=await (await read("/v1/"+id+"/content")).json();assert.equal(live.content.length,1);assert.equal(live.content[0].text,"Reviewed public bio.");
  assert.equal((await read("/v1/"+id+"/content/"+privateId)).status,404);
  assert.equal((await (await read("/v1/"+id+"/content?type=faq")).json()).total,0);
  assert.equal((await (await read("/v1/"+id+"/content?q=PUBLIC")).json()).total,1);
  assert.equal((await read("/v1/"+id+"/content?limit=9000")).status,400);
  const md=await read("/v1/"+id+"/index.md");assert.ok(md.headers.get("Content-Type").startsWith("text/markdown"));assert.ok(!(await md.text()).includes("PRIVATE"));
  assert.equal(await (await read("/v1/"+id+"/profile",{method:"HEAD"})).text(),"");
  assert.equal((await read("/publish",{method:"POST",body:"{}"})).status,401);
  assert.equal((await read("/publish",{method:"POST",headers:{"X-Unsite-Publish-Key":"b".repeat(64)},body:"{}"})).status,401);
  assert.equal((await read("/v1/"+id+"/content",{method:"POST"})).status,405);
  draft.entries[0].content="Updated approved bio.";
  saved=await call("","POST",{id,revision:1,draft});assert.equal(saved.status,200);
  assert.equal((await call("","POST",{id,revision:1,draft})).status,409,"Stale saves must not overwrite newer work");
  assert.equal((await (await read("/v1/"+id+"/content")).json()).content[0].text,"Reviewed public bio.","Draft edits must not change public content");
  assert.equal((await call("/"+id+"/publish","POST",{revision:1,reviewed:true})).status,409);
  assert.equal((await call("/"+id+"/publish","POST",{revision:2,reviewed:true})).status,200);
  assert.equal((await (await read("/v1/"+id+"/content")).json()).content[0].text,"Updated approved bio.");
  const schema=await (await read("/v1/"+id+"/openapi.json")).json();assert.equal(schema.openapi,"3.1.0");assert.ok(schema.paths["/content/{id}"]);
  const stripped=cleanPublication({...publicContent(draft),private:"hidden",content:publicContent(draft).content.map(e=>({...e,source:{original:"hidden"}}))});assert.ok(!JSON.stringify(stripped).includes("hidden"));
  assert.equal((await call("/"+id+"/publish","DELETE",{revision:2,reviewed:true})).status,200);
  assert.equal((await read("/v1/"+id+"/profile")).status,404);assert.equal((await read("/v1/"+id+"/index.md")).status,404);
  assert.equal((await call("/"+id)).body.workspace.draft.entries.length,2);
  console.log("PASS: private persistence, ownership, CSRF, stale writes, explicit review, publication projection, public read/filter/Markdown, updates, and unpublishing.");
}finally{globalThis.fetch=nativeFetch;database.close();}
