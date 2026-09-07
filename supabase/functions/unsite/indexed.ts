import {deliverV2} from "./v2.ts";
import {deliverMcp} from "./mcp.ts";
import {searchKnowledge,terms,indexedQuery} from "../../../lib/production/retrieval.ts";
import type {PublishedRecord,PublicRelease} from "../../../lib/production/release.ts";
type Rest=(path:string,options?:RequestInit)=>Promise<unknown>;
type Metadata=PublicRelease&{record_count:number;authority:unknown};
const uuid=/^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;
const headers={"Cache-Control":"no-store","X-Content-Type-Options":"nosniff","Access-Control-Allow-Origin":"*","Access-Control-Expose-Headers":"X-Unsite-Release, Link, ETag","Access-Control-Allow-Methods":"GET, HEAD, OPTIONS","Access-Control-Allow-Headers":"Accept, Content-Type, If-None-Match"};
const json=(value:unknown,status=200)=>Response.json(value,{status,headers});
export async function deliverIndexed(request:Request,parts:string[],runtimeUrl:string,rest:Rest,publicOrigin:string){
  const rpc=(name:string,body:unknown)=>rest("rpc/"+name,{method:"POST",body:JSON.stringify(body)});
  const url=new URL(request.url),sid=parts[1],resource=parts[2]||"manifest.json";
  if(!uuid.test(sid||"")||parts.length>4)return json({error:"Publication not found."},404);
  if(parts[3]&&resource!=="records")return json({error:"Endpoint not found."},404);
  if(!["manifest.json","profile","records","search","mcp","authority","resources","bundle.json","openapi.json","llms.txt","index.md","catalog.md","topics"].includes(resource))return json({error:"Endpoint not found."},404);
  if(resource!=="mcp"&&!["GET","HEAD"].includes(request.method))return new Response(null,{status:405,headers:{...headers,Allow:"GET, HEAD, OPTIONS"}});
  if(!await rpc("unsite_public_read_budget",{space_id:sid}))return Response.json({error:"This publication is receiving too many requests. Retry shortly."},{status:429,headers:{...headers,"Retry-After":"60"}});
  const release=await rpc("unsite_public_metadata",{space_id:sid}) as Metadata|null;
  if(!release)return json({error:"Publication not found."},404);
  if(url.searchParams.has("release")&&url.searchParams.get("release")!==release.id)return json({error:"Publication changed. Rediscover before continuing.",release_id:release.id},409);
  const base=runtimeUrl+"/functions/v1/unsite/v2/"+sid,canonical=publicOrigin+"/p/"+sid;
  const meta={schema_version:release.data.schema_version,id:sid,release_id:release.id,revision:release.revision,source_revision:release.source_revision,published_at:release.published_at};
  const read=async(options:Record<string,unknown>={})=>{
    const value=await rpc("unsite_public_records",{space_id:sid,p_release:release.id,...options}) as {changed?:boolean;records:PublishedRecord[];total:number}|null;
    if(!value)throw new Error("UNPUBLISHED");if(value.changed)throw new Error("RELEASE_CHANGED");return value;
  };
  const search=async(q:string,limit=8,type?:string,kind?:string,topic?:string)=>{
    // Database stemming selects candidates; the shared scorer produces qualified
    // excerpts. OR syntax is constructed only from normalized letter/number terms.
    const tokens=terms(q),query=indexedQuery(q);
    if(!tokens.length)return {query:q,results:[],total:0,matched:false};
    const found=await read({query_text:query,page_limit:Math.min(100,limit*5),type_filter:type||"",kind_filter:kind||"",topic_filter:topic||""});
    const ranked=searchKnowledge({...release.data,records:found.records},q,{limit,base,release_id:release.id,indexedMatches:true});
    return {...ranked,total:found.total,matched:ranked.results.length>0};
  };
  let response:Response;
  try{
    if(resource==="mcp")return await deliverMcp(request,release,base,{search:async(q,type)=>search(q,8,type),fetch:async id=>uuid.test(id)?(await read({record_id:id,page_limit:1})).records[0]||null:null,list:async offset=>read({page_offset:offset,page_limit:50})});
    if(resource==="search"){
      const q=url.searchParams.get("q")||"",limit=Number(url.searchParams.get("limit")||8),type=url.searchParams.get("type")?.trim(),kind=url.searchParams.get("kind")||undefined,topic=url.searchParams.get("topic")||undefined;
      if(q.trim().length<2||q.length>300||!Number.isInteger(limit)||limit<1||limit>20||(type&&type.length>100)||(topic&&topic.length>100)||(kind&&!["about","person","offering","project","faq","policy","location","general"].includes(kind)))return json({error:"Use q (2–300 characters), limit (1–20), and optional type, kind, or topic filters."},400);
      response=json({...meta,...await search(q,limit,type,kind,topic),retrieval:{method:"indexed lexical search",answer_generation:false}});
    }else if(resource==="records"&&parts[3]){
      if(!uuid.test(parts[3]))return json({error:"Record not found."},404);
      release.data={...release.data,records:(await read({record_id:parts[3],page_limit:1})).records};
      response=await deliverV2(request,parts,runtimeUrl,async()=>[{id:sid,release}]);
    }else if(resource==="records"){
      const offset=Number(url.searchParams.get("offset")||0),limit=Number(url.searchParams.get("limit")||50),q=url.searchParams.get("q")||"",type=url.searchParams.get("type")?.trim()||"",kind=url.searchParams.get("kind")||"";
      if(!Number.isSafeInteger(offset)||offset<0||!Number.isSafeInteger(limit)||limit<1||limit>100||q.length>200||type.length>100||(kind&&!["about","person","offering","project","faq","policy","location","general"].includes(kind)))return json({error:"Invalid filter or pagination."},400);
      const found=await read({page_offset:offset,page_limit:limit,query_text:indexedQuery(q),type_filter:type,kind_filter:kind});
      response=json({...meta,...found,offset,limit});
    }else if(resource==="authority")response=json({...meta,publisher:release.data.publisher||null,verification:release.authority,notice:"Domain control proves control of the listed domain. Publisher approval and evidence support are separate assurances; this is not independent factual verification."});
    else if(resource==="resources")response=json({...meta,resources:release.data.resources||[]});
    else{
      if(!["profile","openapi.json"].includes(resource))release.data={...release.data,records:(await read({page_limit:1000})).records};
      response=await deliverV2(request,parts,runtimeUrl,async()=>[{id:sid,release}]);
      if(["manifest.json","profile","bundle.json"].includes(resource)&&response.ok&&request.method!=="HEAD"){
        const value=await response.json();response=json({...value,canonical_url:canonical,authority:release.authority,links:{...value.links,html:canonical,authority:base+"/authority",resources:base+"/resources"},retrieval:{method:"indexed lexical search",answer_generation:false}});
      }
      if(resource==="openapi.json"&&response.ok&&request.method!=="HEAD"){
        const value=await response.json();
        const read=(operationId:string,summary:string)=>({get:{operationId,summary,parameters:[{name:"release",in:"query",schema:{type:"string",format:"uuid"}}],responses:{"200":{description:"Current approved metadata",content:{"application/json":{schema:{type:"object"}}}},"404":{description:"Publication unavailable"},"409":{description:"Release changed"},"429":{description:"Read limit reached; respect Retry-After"}}}});
        value.paths["/authority"]=read("getPublisherAuthority","Read publisher identity and the current scope, date, and expiry of domain-control verification");
        value.paths["/resources"]=read("listPublicResources","Discover approved public resource URLs, descriptions, formats, versions, and dates; linked files may change outside this release");
        value["x-unsite-canonical"]=canonical;
        value["x-unsite-caching"]="ETag supports If-None-Match. Access is checked before 304; unpublishing removes access to every release. Read requests are limited to 3,000 per publication per minute.";
        response=json(value);
      }
      if(["llms.txt","index.md","catalog.md"].includes(resource)&&response.ok&&request.method!=="HEAD"){
        const content=await response.text();response=new Response(content+`\n## Publisher and resources\n- [Canonical publication](${canonical})\n- [Domain verification](${base}/authority)\n- [Approved resources](${base}/resources?release=${release.id})\n`,{headers:response.headers});
      }
    }
  }catch(error){
    if(error instanceof Error&&error.message==="UNPUBLISHED")return json({error:"Publication not found."},404);
    if(error instanceof Error&&error.message==="RELEASE_CHANGED")return json({error:"Publication changed. Rediscover before continuing."},409);
    throw error;
  }
  if(response.ok){
    const digest=await crypto.subtle.digest("SHA-256",new TextEncoder().encode(release.id+url.pathname+url.search+JSON.stringify(release.authority)));
    const etag='"'+[...new Uint8Array(digest)].map(b=>b.toString(16).padStart(2,"0")).join("")+'"';
    response.headers.set("ETag",etag);response.headers.set("Cache-Control","public, max-age=0, must-revalidate");response.headers.set("X-Unsite-Release",release.id);
    response.headers.set("Access-Control-Expose-Headers","X-Unsite-Release, Link, ETag");response.headers.set("Link",`<${canonical}${resource==="records"&&parts[3]?"/records/"+parts[3]:""}>; rel="canonical", <${base}/openapi.json>; rel="service-desc"`);
    if(request.headers.get("If-None-Match")?.split(/\s*,\s*/).includes(etag))return new Response(null,{status:304,headers:response.headers});
  }
  return request.method==="HEAD"?new Response(null,{status:response.status,headers:response.headers}):response;
}
