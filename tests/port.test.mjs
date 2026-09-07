import {createRequire} from "node:module";
import {fileURLToPath} from "node:url";
import {readFile} from "node:fs/promises";
import {randomUUID} from "node:crypto";
import assert from "node:assert/strict";
import {DatabaseSync} from "node:sqlite";
const root=fileURLToPath(new URL("..",import.meta.url)).replace(/\/$/,"");
const require=createRequire(root+"/package.json");
const {build}=require("esbuild");

const source=[
'import * as sites from "'+root+'/app/api/sites/route.ts";',
'import * as detail from "'+root+'/app/api/sites/[id]/route.ts";',
'import * as agent from "'+root+'/app/api/agent/[id]/[resource]/route.ts";',
'import * as scan from "'+root+'/app/api/scan/route.ts";',
'import {parseHtml} from "'+root+'/lib/scanner.ts";',
'import {normalizeWebsite,publicAddress,robotsAllows,childLinks} from "'+root+'/lib/scan-utils.ts";',
'export default {async fetch(r){const u=new URL(r.url);if(u.pathname==="/inspect"){return Response.json(await parseHtml(await r.text()))}if(u.pathname==="/utils"){return Response.json({blocked:["http://foo.com","https://127.0.0.1","https://0x7f000001","https://user:pass@example.org","https://test.local","https://[::1]"].map(v=>{try{normalizeWebsite(v);return false}catch{return true}}),public:[publicAddress("8.8.8.8"),publicAddress("1.1.1.1"),publicAddress("2606:4700:4700::1111")],private:[publicAddress("10.0.0.1"),publicAddress("169.254.169.254"),publicAddress("::ffff:127.0.0.1"),publicAddress("2001:db8::1")],robots:[robotsAllows("User-agent: *\\nDisallow: /private\\nAllow: /private/help",new URL("https://example.org/private/a")),robotsAllows("User-agent: *\\nDisallow: /private\\nAllow: /private/help",new URL("https://example.org/private/help"))],links:childLinks(["/contact","/checkout","https://evil.org","mailto:x@y.z"],new URL("https://example.org")).map(x=>x.pathname)})}if(u.pathname==="/api/sites")return sites[r.method](r);if(u.pathname==="/api/scan")return scan.POST(r);let p=u.pathname.split("/");if(p[2]==="agent")return agent.GET(r,{params:Promise.resolve({id:p[3],resource:p[4]})});return detail.GET(r,{params:Promise.resolve({id:p[3]})})}}'
].join("\n");
const database=new DatabaseSync(":memory:");
globalThis.__PORT_TEST_ENV__={DB:{prepare(sql){let values=[];const statement=database.prepare(sql);return {bind(...v){values=v;return this},async run(){statement.run(...values);return {success:true}},async all(){return {results:statement.all(...values),success:true}},async first(){return statement.get(...values)||null}}}}};
const bundle=await build({stdin:{contents:source,loader:"ts",resolveDir:root},bundle:true,format:"esm",platform:"node",mainFields:["module","main"],write:false,tsconfig:root+"/tsconfig.json",logLevel:"silent",plugins:[{name:"in-memory-env",setup(b){b.onResolve({filter:/^cloudflare:workers$/},()=>({path:"worker-env",namespace:"test"}));b.onLoad({filter:/.*/,namespace:"test"},()=>({contents:"export const env=globalThis.__PORT_TEST_ENV__",loader:"js"}))}}]});
const {default:worker}=await import("data:text/javascript;base64,"+Buffer.from(bundle.outputFiles[0].text).toString("base64"));
try{
const migration=await readFile(root+"/drizzle/0000_classy_doorman.sql","utf8");
database.exec(migration.replaceAll("--> statement-breakpoint",""));
async function call(path,options={},identity="owner-a"){const headers={"Content-Type":"application/json",...(identity?{"oai-authenticated-user-email":identity+"@example.com"}:{}),...options.headers};const response=await worker.fetch(new Request("https://port.test"+path,{...options,headers}));return {status:response.status,body:await response.json()}}
assert.equal((await call("/api/sites",{},"")).status,401);
assert.equal((await call("/api/scan",{method:"POST",body:JSON.stringify({url:"",sample:true})},"")).status,401);
const scanned=await call("/api/scan",{method:"POST",body:JSON.stringify({url:"",sample:true})});
assert.equal(scanned.status,200);const draft=scanned.body.draft;
draft.business.name="Owner-reviewed studio";draft.pages[0].included=false;
const id=randomUUID();
const saved=await call("/api/sites",{method:"POST",body:JSON.stringify({id,draft})});
assert.equal(saved.status,200,JSON.stringify(saved.body));
assert.equal((await call("/api/sites")).body.sites.length,1);
assert.equal((await call("/api/sites",{},"OWNER-A")).body.sites.length,1);
const read=await call("/api/agent/"+id+"/business");
assert.equal(read.status,200);assert.equal(read.body.name,"Owner-reviewed studio");
assert.equal((await call("/api/agent/"+id+"/pages")).body.pages.length,2);
assert.equal((await call("/api/agent/"+id+"/business",{},"owner-b")).status,404);
assert.equal((await call("/api/agent/"+id+"/business",{},"")).status,401);
const collision=await call("/api/sites",{method:"POST",body:JSON.stringify({id,draft:{...draft,business:{...draft.business,name:"Intruder"}}})},"owner-b");
assert.equal(collision.status,404);assert.equal((await call("/api/agent/"+id+"/business")).body.name,"Owner-reviewed studio");
draft.business.description="An updated description";
assert.equal((await call("/api/sites",{method:"POST",body:JSON.stringify({id,draft})})).status,200);
assert.equal((await call("/api/agent/"+id+"/business")).body.description,"An updated description");
assert.equal((await call("/api/sites")).body.sites.length,1);
const spec=await call("/api/agent/"+id+"/openapi.json");assert.equal(spec.body.openapi,"3.1.0");assert.deepEqual(Object.keys(spec.body.paths),["/business","/services","/pages"]);
const utils=(await call("/utils")).body;
assert.ok(utils.blocked.every(Boolean));assert.ok(utils.public.every(Boolean));assert.ok(utils.private.every(v=>!v));assert.deepEqual(utils.robots,[false,true]);assert.deepEqual(utils.links,["/contact"]);
console.log("PASS: verified email-only sign-in, sample import, real SQLite save/read/update, owner isolation, excluded pages, schema, and crawl guards.");
}finally{database.close()}
