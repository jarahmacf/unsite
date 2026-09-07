import {chunks,ProcessingError} from "./parser.ts";
import {prepareWithUsage} from "./prepare.ts";
type Job={id:string;source_version_id:string;lease_token:string;cursor:number};
type Rest=(path:string,body?:unknown)=>Promise<any>;
export async function prepareAuthorizedJob(job:Job,text:string,config:{key:string;model:string},rest:Rest,requestFetch:typeof fetch=fetch){
  const report=(result:unknown)=>rest("rpc/unsite_job_result",{job_id:job.id,lease:job.lease_token,result});
  let dispatchId:string|undefined;
  try{
    const active=await rest("unsite_ai_authorizations?source_version_id=eq."+job.source_version_id+"&revoked_at=is.null&select=id&limit=1");
    if(!active.length)throw new ProcessingError("AI_APPROVAL_REQUIRED","The original is saved and ready. Choose Prepare with AI to approve sending this source version's extracted text to OpenAI.","blocked");
    if(!config.key||!config.model)throw new ProcessingError("MODEL_NOT_CONFIGURED","AI preparation is approved for this source version. The application's OpenAI connection still needs to be configured; your source is saved.","blocked");
    const passage=chunks(text)[job.cursor];
    if(!passage)throw new ProcessingError("INVALID_CHECKPOINT","This source's preparation checkpoint needs attention. No AI request was made.","blocked");
    const dispatch=await rest("rpc/unsite_ai_dispatch",{p_job_id:job.id,p_lease:job.lease_token,p_model:config.model});
    if(!dispatch.allowed){
      if(["STALE_LEASE","ALREADY_DISPATCHED","SOURCE_ARCHIVED"].includes(dispatch.reason))return false;
      if(dispatch.reason==="AI_DAILY_LIMIT")throw new ProcessingError("AI_DAILY_LIMIT","This workspace or service has reached its development preparation limit. Retry when capacity is available.","blocked");
      throw new ProcessingError("AI_APPROVAL_REQUIRED","AI preparation is no longer authorized for this source version.","blocked");
    }
    dispatchId=dispatch.dispatch_id;
    const result=await prepareWithUsage(passage,job.source_version_id,job.cursor,config,requestFetch);
    await rest("rpc/unsite_ai_finish",{p_dispatch_id:dispatchId,p_status:"succeeded",p_response_id:result.responseId,p_input_tokens:result.inputTokens,p_output_tokens:result.outputTokens});
    return await report({mode:"chunk",cursor:job.cursor,dispatch_id:dispatchId,candidates:result.candidates});
  }catch(error){
    const e=error instanceof ProcessingError?error:new ProcessingError("PROVIDER_UNCERTAIN","Preparation stopped before its result could be saved. Retry when ready; a repeated request may incur another provider charge.","blocked");
    if(dispatchId){
      try{await rest("rpc/unsite_ai_finish",{p_dispatch_id:dispatchId,p_status:e.code==="PROVIDER_UNCERTAIN"?"uncertain":"failed"});}catch{/* The lease reaper will preserve an uncertain outcome. */}
    }
    return await report({mode:"error",code:e.code,message:e.message,disposition:e.disposition});
  }
}
