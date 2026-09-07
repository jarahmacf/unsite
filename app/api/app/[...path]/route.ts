export const dynamic="force-dynamic";
import {z} from "zod";
import {commandSchemas} from "@/lib/production/contracts";
import {apiError,AppError,databaseError,readJson,requestClient,writeGuard,type AppContext} from "@/lib/production/supabase";
import {inspectKnowledge,runRetrievalCases,type RetrievalCase} from "@/lib/production/retrieval";
import type {Snapshot} from "@/lib/production/release";
import {presenceActions} from "@/lib/production/presence";

const uuid=z.string().uuid();
async function authenticated(request:Request,ctx:AppContext){
  const {data,error}=await ctx.supabase.auth.getUser();
  if(error||!data.user)throw new AppError(401,"Sign in to open your workspace.");
  return data.user;
}
async function worker(ctx:AppContext,method="GET"){
  if(!ctx.config.workerToken)return null;
  try{
    const r=await fetch(ctx.config.workerUrl,{method,headers:{"X-Unsite-Worker-Key":ctx.config.workerToken,Authorization:"Bearer "+ctx.config.workerGatewayKey},signal:AbortSignal.timeout(4000)});
    return r.ok?await r.json():null;
  }catch{return null;} // The durable queue is picked up by the scheduled worker.
}
function route(request:Request){return new URL(request.url).pathname.replace(/^\/api\/app\//,"").replace(/\/$/,"");}
export async function GET(request:Request){
  let ctx:AppContext|undefined;
  try{
    ctx=requestClient(request);await authenticated(request,ctx);
    const url=new URL(request.url),path=route(request),client=ctx.supabase;
    let result:unknown;
    if(path==="presence"){
      const space=uuid.parse(url.searchParams.get("space"));
      const {data,error}=await client.rpc("unsite_presence_state",{space_id:space});databaseError(error);result=data;
    }else if(path==="spaces"){
      const {data,error}=await client.from("unsite_spaces").select("*").order("created_at");databaseError(error);result={spaces:data};
    }else if(path==="status"){
      const status=await worker(ctx);
      result={storage:true,processing:Boolean(status?.worker),model:Boolean(status?.model),modelName:status?.modelName||null,publicBase:ctx.config.publicBase,publicOrigin:ctx.config.publicOrigin,domains:false};
    }else if(path==="state"){
      const spaceId=uuid.parse(url.searchParams.get("space"));
      const candidateLimit=z.coerce.number().int().min(100).max(1000).parse(url.searchParams.get("candidate_limit")||100);
      const queries=await Promise.all([
        client.from("unsite_spaces").select("*").eq("id",spaceId).single(),
        client.from("unsite_sources").select("*").eq("space_id",spaceId).order("created_at",{ascending:false}),
        client.from("unsite_source_versions").select("id,source_id,space_id,version,storage_path,mime_type,byte_size,content_hash,created_at").eq("space_id",spaceId).order("version",{ascending:false}),
        client.from("unsite_jobs").select("id,space_id,source_version_id,status,stage,attempts,max_attempts,progress,error_code,error_message,run_after,created_at,updated_at").eq("space_id",spaceId).order("created_at",{ascending:false}),
        client.from("unsite_candidates").select("*",{count:"exact"}).eq("space_id",spaceId).eq("status","proposed").eq("review_ready",true).order("created_at").order("id").range(0,candidateLimit-1),
        client.from("unsite_records").select("*",{count:"exact"}).eq("space_id",spaceId).order("updated_at",{ascending:false}).range(0,199),
        client.from("unsite_releases").select("id,space_id,revision,source_revision,summary,created_by,published_at").eq("space_id",spaceId).order("revision",{ascending:false}).limit(100),
        client.from("unsite_events").select("*").eq("space_id",spaceId).order("created_at",{ascending:false}).limit(60),
        client.from("unsite_memberships").select("role,user_id").eq("space_id",spaceId),
        client.from("unsite_ai_authorizations").select("id,space_id,source_version_id,provider,authorized_by,authorized_at,revoked_at,disclosure_version").eq("space_id",spaceId).is("revoked_at",null),
      ]);
      if(!queries[0].data)throw new AppError(404,"Workspace not found.");
      for(const q of queries)databaseError(q.error);
      const names=["space","sources","versions","jobs","candidates","records","releases","activity","memberships","aiAuthorizations"];
      result={...Object.fromEntries(names.map((name,i)=>[name,queries[i].data])),candidateCount:queries[4].count,recordCount:queries[5].count};
    }else if(path==="workspace-settings"||path==="workspace-export"){
      const space=uuid.parse(url.searchParams.get("space"));
      const {data,error}=await client.rpc(path==="workspace-settings"?"unsite_workspace_settings":"unsite_workspace_export",{space_id:space});databaseError(error);
      if(path==="workspace-export"){
        const bytes=new TextEncoder().encode(JSON.stringify(data)),headers=new Headers(ctx.headers);let offset=0;
        headers.set("Content-Type","application/json; charset=utf-8");
        headers.set("Content-Disposition",`attachment; filename="unsite-workspace-${space}.json"`);
        return new Response(new ReadableStream({pull(controller){if(offset>=bytes.length){controller.close();return;}controller.enqueue(bytes.slice(offset,offset+65536));offset+=65536;}}),{headers});
      }
      result=data;
    }else if(path==="record-directory"){
      const input=z.object({space_id:uuid,search_query:z.string().trim().max(300),content_type:z.string().trim().max(100),inclusion:z.enum(["all","included","excluded"]),page_offset:z.coerce.number().int().min(0).max(100000),page_limit:z.coerce.number().int().min(1).max(100)}).parse({space_id:url.searchParams.get("space"),search_query:url.searchParams.get("q")||"",content_type:url.searchParams.get("type")||"",inclusion:url.searchParams.get("inclusion")||"all",page_offset:url.searchParams.get("offset")||0,page_limit:url.searchParams.get("limit")||24});
      const {data,error}=await client.rpc("unsite_record_directory",input);databaseError(error);result=data;
    }else if(path==="activity"){
      const space=uuid.parse(url.searchParams.get("space")),offset=z.coerce.number().int().min(0).max(100000).parse(url.searchParams.get("offset")||0);
      const {data,error,count}=await client.from("unsite_events").select("*",{count:"exact"}).eq("space_id",space).order("created_at",{ascending:false}).order("id",{ascending:false}).range(offset,offset+49);databaseError(error);result={items:data,count};
    }else if(path==="collection-runs"){
      const space=uuid.parse(url.searchParams.get("space")),id=url.searchParams.get("id");
      const {data,error}=await client.rpc("unsite_collection_overview",{p_space_id:space,p_run_id:id?uuid.parse(id):null});
      if(error?.code==="PGRST202")result={configured:false,runs:[]};
      else{databaseError(error);result={configured:true,runs:data};}
    }else if(path==="evidence"){
      const id=uuid.parse(url.searchParams.get("id"));
      const {data,error}=await client.from("unsite_evidence_segments").select("*").eq("id",id).single();databaseError(error);
      if(!data)throw new AppError(404,"Evidence not found.");result={segment:data};
    }else if(path==="knowledge"){
      const space=uuid.parse(url.searchParams.get("space"));
      const {data,error}=await client.rpc("unsite_knowledge_snapshot",{space_id:space});databaseError(error);
      if(!data)throw new AppError(404,"Workspace not found.");
      const cases=await client.from("unsite_retrieval_cases").select("*").eq("space_id",space).order("created_at");databaseError(cases.error);
      result={...data,cases:cases.data};
    }else if(path==="comparisons"){
      const id=uuid.parse(url.searchParams.get("candidate"));const {data,error}=await client.rpc("unsite_compare_candidate",{candidate_id:id});databaseError(error);result={matches:data};
    }else if(path==="record"){
      const id=uuid.parse(url.searchParams.get("id"));
      const [record,links,history]=await Promise.all([client.from("unsite_records").select("*").eq("id",id).single(),client.from("unsite_record_links").select("target_id,relation").eq("record_id",id),client.from("unsite_record_evidence").select("candidate_id,record_revision,recorded_at").eq("record_id",id).order("record_revision",{ascending:false}).limit(30)]);
      for(const q of [record,links,history])databaseError(q.error);
      if(!record.data)throw new AppError(404,"Record not found.");
      const ids=[...new Set((history.data||[]).map(h=>h.candidate_id))];
      const evidence=ids.length?await client.from("unsite_candidates").select("id,title,evidence,source_version_id").in("id",ids):{data:[],error:null};databaseError(evidence.error);
      result={record:record.data,links:links.data,history:history.data,evidence:evidence.data};
    }else if(path==="agent-check"){
      const space=uuid.parse(url.searchParams.get("space")),mode=url.searchParams.get("mode")||"draft";
      if(!["draft","published"].includes(mode))throw new AppError(400,"Choose draft or published knowledge.");
      const current=await client.rpc("unsite_knowledge_snapshot",{space_id:space});databaseError(current.error);if(!current.data)throw new AppError(404,"Workspace not found.");
      const cases=await client.from("unsite_retrieval_cases").select("*").eq("space_id",space).order("created_at");databaseError(cases.error);
      let snapshot=current.data.snapshot as Snapshot,releaseId:string|null=null,transport:unknown=null;
      if(mode==="published"){
        const base=ctx.config.publicBase+"/"+space;
        const manifest=await fetch(base,{headers:{Accept:"application/json"},signal:AbortSignal.timeout(8000)});
        if(!manifest.ok)throw new AppError(manifest.status===404?404:503,"The published presence could not be reached.");
        const entry=await manifest.json() as {release_id:string};releaseId=uuid.parse(entry.release_id);
        const bundle=await fetch(base+"/bundle.json?release="+releaseId,{signal:AbortSignal.timeout(8000)});
        if(bundle.status===409)throw new AppError(409,"The publication changed during this check. Run it again.");
        if(!bundle.ok)throw new AppError(503,"The public knowledge could not be retrieved.");
        const published=await bundle.json() as Snapshot&{release_id:string;source_revision:number};
        if(published.release_id!==releaseId)throw new AppError(409,"The publication changed during this check. Run it again.");
        snapshot=published;
        const checks=await Promise.all((cases.data as RetrievalCase[]).map(async c=>{
          const response=await fetch(base+"/search?q="+encodeURIComponent(c.question)+"&limit=5&release="+releaseId,{signal:AbortSignal.timeout(8000)});
          if(!response.ok)return {...c,passed:false,error:response.status===409?"Publication changed. Run the check again.":"Public retrieval failed.",returned_ids:[],returned_titles:[]};
          const found=await response.json() as {results:{id:string;title:string}[];matched:boolean};
          return {...c,passed:c.expectation==="no_match"?!found.matched:found.results.some(r=>r.id===c.expected_record_id),returned_ids:found.results.map(r=>r.id),returned_titles:found.results.map(r=>r.title)};
        }));
        transport={entry_point:base,manifest_status:manifest.status,bundle_status:bundle.status,checked_at:new Date().toISOString()};
        result={mode,release_id:releaseId,source_revision:published.source_revision,inspection:inspectKnowledge(snapshot),cases:checks,transport};
      }else result={mode,source_revision:current.data.source_revision,inspection:inspectKnowledge(snapshot),cases:runRetrievalCases(snapshot,cases.data as RetrievalCase[]),transport};
    }else if(path==="candidates"||path==="records"||path==="releases"){
      const space=uuid.parse(url.searchParams.get("space")),offset=z.coerce.number().int().min(0).max(100000).parse(url.searchParams.get("offset")||0);
      let query=client.from("unsite_"+path).select(path==="releases"?"id,space_id,revision,source_revision,summary,created_by,published_at":"*",{count:"exact"}).eq("space_id",space);
      if(path==="candidates")query=query.eq("status","proposed").eq("review_ready",true).order("created_at").order("id");
      else query=query.order(path==="records"?"updated_at":"revision",{ascending:false}).order("id");
      const {data,error,count}=await query.range(offset,offset+99);databaseError(error);result={items:data,count};
    }else if(path==="version"){
      const id=uuid.parse(url.searchParams.get("id"));
      const {data,error}=await client.from("unsite_source_versions").select("*").eq("id",id).single();databaseError(error);
      if(!data)throw new AppError(404,"Source not found.");
      let downloadUrl:null|string=null;
      if(data.storage_path){const signed=await client.storage.from("unsite-sources").createSignedUrl(data.storage_path,60,{download:true});databaseError(signed.error);downloadUrl=signed.data?.signedUrl||null;}
      result={version:data,downloadUrl};
    }else if(path==="release"){
      const id=uuid.parse(url.searchParams.get("id"));
      const {data,error}=await client.from("unsite_releases").select("*").eq("id",id).single();databaseError(error);
      if(!data)throw new AppError(404,"Release not found.");result={release:data};
    }else throw new AppError(404,"This endpoint does not exist.");
    return Response.json(result,{headers:ctx.headers});
  }catch(e){return apiError(e,ctx?.headers);}
}
export async function POST(request:Request){
  let ctx:AppContext|undefined;
  try{
    writeGuard(request);ctx=requestClient(request);await authenticated(request,ctx);
    const action=route(request);
    if(!(action in commandSchemas))throw new AppError(404,"This command does not exist.");
    const payload=commandSchemas[action as keyof typeof commandSchemas].parse(await readJson(request));
    const rpc=presenceActions.includes(action)?"unsite_presence_command":["restore_source","create_invitation","accept_invitation","revoke_invitation","update_member","remove_member","leave_workspace"].includes(action)?"unsite_workspace_command":["start_collection_run","cancel_collection_run","resume_collection_run"].includes(action)?"unsite_collection_command":["prepare_source","stop_preparation"].includes(action)?"unsite_ai_command":["save_retrieval_case","delete_retrieval_case"].includes(action)?"unsite_retrieval_case_command":"unsite_command";
    const {data,error}=await ctx.supabase.rpc(rpc,{action,payload});databaseError(error);
    let upload:unknown=null,uploadComplete=false;
    if(action==="source_intake"&&data.storage_path){
      const completed=await ctx.supabase.rpc("unsite_command",{action:"complete_upload",payload:{space_id:data.space_id,version_id:data.id}});
      if(!completed.error)uploadComplete=true;
      else if(completed.error.message.includes("Upload is not complete")){
        const signed=await ctx.supabase.storage.from("unsite-sources").createSignedUploadUrl(data.storage_path,{upsert:false});databaseError(signed.error);
        upload={signedUrl:signed.data?.signedUrl,path:data.storage_path};
      }else databaseError(completed.error);
    }
    // Await only the worker's acknowledgement. Long work runs on its durable queue.
    if(["source_intake","complete_upload","retry_job","prepare_source","start_collection_run","resume_collection_run","claim_domain","check_domain","save_monitor","check_source","check_delivery"].includes(action)&&(!data.storage_path||uploadComplete))await worker(ctx,"POST");
    return Response.json({result:data,upload,uploadComplete},{headers:ctx.headers});
  }catch(e){return apiError(e,ctx?.headers);}
}
