import {importPage} from "./crawler.ts";
import {ProcessingError} from "./parser.ts";

type MaintenanceTask={kind:"domain"|"source"|"delivery";id:string;space_id:string;lease:string;release_id?:string;domain?:string;challenge?:string;url?:string;previous_text?:string|null};
type Rest=(path:string,body?:unknown)=>Promise<any>;
export async function runMaintenanceStep(rest:Rest,deps:{resolve:(host:string)=>Promise<string[]>;txt:(host:string)=>Promise<string[][]>;html:(text:string)=>string;fetch:typeof fetch;delivery?:(spaceId:string,releaseId:string)=>Promise<unknown>}){
  const task=await rest("rpc/unsite_claim_maintenance",{}) as MaintenanceTask|null;
  if(!task)return false;
  const finish=(p_result:unknown)=>rest("rpc/unsite_maintenance_result",{p_kind:task.kind,p_id:task.id,p_lease:task.lease,p_result});
  try{
    if(task.kind==="delivery"){
      if(!deps.delivery||!task.release_id)throw new Error("Delivery checker unavailable");
      await finish(await deps.delivery(task.space_id,task.release_id));
    }else if(task.kind==="domain"){
      const records=await deps.txt("_unsite."+task.domain);
      const expected="unsite="+task.space_id+"."+task.challenge;
      await finish({verified:records.some(parts=>parts.join("").trim()===expected)});
    }else{
      const text=await importPage(task.url!,deps);
      if(text.length>200000)throw new ProcessingError("TEXT_LIMIT","This page exceeds the source text limit. Split it into smaller sources.");
      // The database compares normalized content again under a lock and creates
      // a new immutable version only if needed. No model is called here.
      await finish({text});
    }
  }catch(error){await finish({error:error instanceof ProcessingError?error.message:task.kind==="domain"?"The DNS proof could not be verified. Check the TXT record and try again.":"The source could not be checked. Its last saved version is preserved."});}
  return true;
}
