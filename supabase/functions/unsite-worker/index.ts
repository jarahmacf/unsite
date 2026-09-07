// Deno-only dependencies are pinned independently from the web application.
// @ts-ignore -- npm: imports are resolved by Supabase's Deno runtime.
import {extractText,getDocumentProxy} from "npm:unpdf@1.8.1";
// @ts-ignore -- npm: imports are resolved by Supabase's Deno runtime.
import {parseHTML} from "npm:linkedom@0.18.13";
import {chunks,ProcessingError,sha256} from "./parser.ts";
import {importPage} from "./crawler.ts";
import {prepareAuthorizedJob} from "./processing.ts";
import {checkDelivery} from "../../../lib/production/delivery-check.ts";
import {runCollectionStep} from "./collection.ts";
import {runMaintenanceStep} from "./maintenance.ts";
declare const Deno:{env:{get(name:string):string|undefined};resolveDns(host:string,type:"A"|"AAAA"):Promise<string[]>;resolveDns(host:string,type:"TXT"):Promise<string[][]>;serve(handler:(r:Request)=>Promise<Response>):void};
declare const EdgeRuntime:{waitUntil(promise:Promise<unknown>):void};
const modern=JSON.parse(Deno.env.get("SUPABASE_SECRET_KEYS")||"{}");
const key=modern.default||Deno.env.get("SUPABASE_SERVICE_ROLE_KEY"),url=Deno.env.get("SUPABASE_URL");
if(!key||!url)throw new Error("Worker database credentials are unavailable");
const auth:Record<string,string>={apikey:key,"Content-Type":"application/json"};
if(!key.startsWith("sb_secret_"))auth.Authorization="Bearer "+key;
async function rest(path:string,body?:unknown){const r=await fetch(url+"/rest/v1/"+path,{method:body===undefined?"GET":"POST",headers:auth,...(body===undefined?{}:{body:JSON.stringify(body)}),signal:AbortSignal.timeout(15000)});if(!r.ok)throw new Error("Worker storage request failed");return r.json();}
const modelConfig=()=>({key:Deno.env.get("OPENAI_API_KEY")||"",model:Deno.env.get("UNSITE_MODEL")||"gpt-5-mini-2025-08-07"});
const crawlDeps={fetch,delivery:(spaceId:string,releaseId:string)=>checkDelivery(url+"/functions/v1/unsite/v2/"+spaceId,releaseId,fetch),resolve:async (host:string)=>(await Promise.allSettled([Deno.resolveDns(host,"A"),Deno.resolveDns(host,"AAAA")])).flatMap(r=>r.status==="fulfilled"?r.value:[]),txt:(host:string)=>Deno.resolveDns(host,"TXT"),html:(html:string)=>{const {document}=parseHTML(html);document.querySelectorAll("script,style,nav,footer,header,form,noscript,svg,iframe").forEach((n:{remove:()=>void})=>n.remove());const root=document.querySelector("main,article,[role=main]")||document.body;return (root?.innerText||root?.textContent||"").replace(/\n{3,}/g,"\n\n").trim();}};
async function runSource(){
  const job=await rest("rpc/unsite_claim_job",{});if(!job)return;
  const report=(result:unknown)=>rest("rpc/unsite_job_result",{job_id:job.id,lease:job.lease_token,result});
  let aiStage=false;
  try{
    const [version]=await rest("unsite_source_versions?id=eq."+job.source_version_id+"&select=*&limit=1");
    const [source]=await rest("unsite_sources?id=eq."+version.source_id+"&select=*&limit=1");
    let text:string=version.extracted_text||"";
    if(!text){
      if(source.kind==="text")text=version.text_content||"";
      else if(source.kind==="url")text=await importPage(source.origin_url,{
        fetch,
        resolve:async host=>(await Promise.allSettled([Deno.resolveDns(host,"A"),Deno.resolveDns(host,"AAAA")])).flatMap(r=>r.status==="fulfilled"?r.value:[]),
        html:html=>{const {document}=parseHTML(html);document.querySelectorAll("script,style,nav,footer,header,form,noscript,svg,iframe").forEach((n:{remove:()=>void})=>n.remove());const root=document.querySelector("main,article,[role=main]")||document.body;return (root?.innerText||root?.textContent||"").replace(/\n{3,}/g,"\n\n").trim();},
      });
      else{
        const r=await fetch(url+"/storage/v1/object/authenticated/unsite-sources/"+version.storage_path,{headers:auth,signal:AbortSignal.timeout(25000)});
        if(!r.ok)throw new ProcessingError("UPLOAD_UNAVAILABLE","The original upload could not be read. Retry after checking storage.","retry");
        const bytes=new Uint8Array(await r.arrayBuffer());
        if(bytes.length>20971520)throw new ProcessingError("FILE_LIMIT","This upload exceeds 20 MB.");
        if(version.mime_type==="application/pdf"){
          const pdf=await getDocumentProxy(bytes);
          try{if(pdf.numPages>300)throw new ProcessingError("PAGE_LIMIT","Split PDFs with more than 300 pages into smaller documents.");const result=await extractText(pdf,{mergePages:false});text=(result.text as string[]).map((p,i)=>`[Page ${i+1}]\n${p}`).join("\n\n");if((result.text as string[]).join("").trim().length<40)throw new ProcessingError("NO_TEXT","This PDF has no readable text layer. Upload an accessible PDF or paste its text.");}finally{await pdf.destroy();}
        }else{try{text=new TextDecoder("utf-8",{fatal:true}).decode(bytes);}catch{throw new ProcessingError("TEXT_ENCODING","Save this file as UTF-8 text and upload it again.");}if(version.mime_type==="application/json"){try{JSON.parse(text);}catch{throw new ProcessingError("INVALID_JSON","This JSON file is not valid. Correct it and upload another version.");}}}
      }
      const passages=chunks(text);
      if(!await report({mode:"parsed",text,hash:await sha256(text),chunks:passages.length}))return;
    }
    aiStage=true;
    await prepareAuthorizedJob(job,text,modelConfig(),rest);
  }catch(error){
    const e=error instanceof ProcessingError?error:aiStage?new ProcessingError("PROVIDER_UNCERTAIN","Preparation stopped before a checkpoint was saved. Retry when ready; a repeated request may incur another provider charge.","blocked"):new ProcessingError("PROCESSING_INTERRUPTED","Processing was interrupted. Your source and saved checkpoints are preserved. Retry to continue.","retry");
    await report({mode:"error",code:e.code,message:e.message,disposition:e.disposition});
  }
}
async function run(){
  // Separate lanes prevent a busy collection from starving source parsing or
  // maintenance. A bounded drain advances checkpoints without an open browser.
  const results=await Promise.allSettled([runMaintenanceStep(rest,crawlDeps),runSource(),(async()=>{const start=Date.now();for(let i=0;i<3&&Date.now()-start<100000;i++)if(!await runCollectionStep(rest,modelConfig()))break;})()]);
  results.forEach((result,i)=>{if(result.status==="rejected")console.error("Unsite "+["maintenance","source reading","collection preparation"][i]+" stopped; its lease will expire for recovery");});
}
Deno.serve(async request=>{
  const headers={"Cache-Control":"no-store","X-Content-Type-Options":"nosniff"};
  try{
    if(request.headers.has("Origin"))return Response.json({error:"Server requests only"},{status:403,headers});
    const token=request.headers.get("X-Unsite-Worker-Key")||"";
    if(!/^[a-f0-9]{64}$/.test(token))return Response.json({error:"Authentication required"},{status:401,headers});
    const credentials=await rest("unsite_worker_credentials?token_hash=eq."+await sha256(token)+"&active=eq.true&select=id&limit=1");
    if(!credentials.length)return Response.json({error:"Authentication required"},{status:401,headers});
    if(request.method==="GET"){const config=modelConfig();return Response.json({worker:true,model:Boolean(config.key&&config.model),modelName:config.model,consentRequired:true},{headers});}
    if(request.method!=="POST")return new Response(null,{status:405,headers:{...headers,Allow:"GET, POST"}});
    EdgeRuntime.waitUntil(run().catch(()=>console.error("Unsite worker stopped; lease will expire for recovery")));
    return Response.json({accepted:true},{status:202,headers});
  }catch{return Response.json({error:"Worker unavailable"},{status:503,headers});}
});
