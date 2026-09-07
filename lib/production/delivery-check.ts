export type DeliveryCheck={name:string;passed:boolean;detail:string};
export type DeliveryReport={checked_at:string;release_id:string;checks:DeliveryCheck[];passed:boolean;mode:"direct_http_mcp"};
/** Check an operator-constructed publication base. Never treat user text as a URL. */
export async function checkDelivery(base:string,releaseId:string,requestFetch:typeof fetch=fetch):Promise<DeliveryReport>{
  const checks:DeliveryCheck[]=[];
  async function read(name:string,path:string,validate:(value:any,response:Response)=>boolean){
    try{const response=await requestFetch(base+path,{headers:{Accept:"application/json"},signal:AbortSignal.timeout(12000)});const value=await response.json();const passed=response.ok&&validate(value,response);checks.push({name,passed,detail:passed?"Available and consistent with the active release.":`Unexpected response (HTTP ${response.status}).`});return passed?value:null;}
    catch{checks.push({name,passed:false,detail:"The endpoint could not be read within 12 seconds."});return null;}
  }
  const [profile,records]=await Promise.all([
    read("Published identity","/profile?release="+releaseId,v=>v.release_id===releaseId&&typeof v.name==="string"),
    read("Record directory","/records?limit=1&release="+releaseId,v=>v.release_id===releaseId&&Array.isArray(v.records)&&v.records.length>0),
    read("API definition","/openapi.json",v=>!!v.paths?.["/search"]&&!!v.paths?.["/resources"]),
    read("Resource catalog","/resources?release="+releaseId,v=>v.release_id===releaseId&&Array.isArray(v.resources)),
  ]);
  if(records?.records[0]){
    const id=records.records[0].id;
    await read("Complete record","/records/"+encodeURIComponent(id)+"?release="+releaseId,(v,r)=>v.release_id===releaseId&&v.id===id&&typeof v.text==="string"&&!!r.headers.get("ETag"));
    try{
      const response=await requestFetch(base+"/mcp",{method:"POST",headers:{"Content-Type":"application/json",Accept:"application/json, text/event-stream"},body:JSON.stringify({jsonrpc:"2.0",id:1,method:"tools/call",params:{name:"fetch",arguments:{id,release_id:releaseId}}}),signal:AbortSignal.timeout(12000)});
      const message=await response.json(),record=JSON.parse(message.result?.content?.[0]?.text||"null");const passed=response.ok&&!message.result?.isError&&record?.id===id&&record?.release_id===releaseId;
      checks.push({name:"MCP fetch",passed,detail:passed?"A server client can read the same complete record.":"MCP did not return the expected record and release."});
    }catch{checks.push({name:"MCP fetch",passed:false,detail:"The MCP response could not be read."});}
  }
  if(!profile||!records)checks.push({name:"Publication consistency",passed:false,detail:"The release is unavailable or changed during the check. Retry after publishing finishes."});
  return {checked_at:new Date().toISOString(),release_id:releaseId,checks,passed:checks.every(c=>c.passed),mode:"direct_http_mcp"};
}
