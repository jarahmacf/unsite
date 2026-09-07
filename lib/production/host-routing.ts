export type PublicHost = { space_id:string; hostname:string; probe_token:string; routable:boolean; published:boolean; release_id:string|null };
const uuid=/^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;
export function normalizedHost(value:string){
  if(!/^[a-z0-9.-]+(?::\d{1,5})?$/i.test(value)||value.includes(".."))return null;
  return value.toLowerCase().replace(/:\d+$/,"").replace(/\.$/,"");
}
export function platformHost(host:string,origin:string){
  return host===new URL(origin).hostname||host==="localhost"||host==="127.0.0.1"||host.endsWith(".vercel.app")||host.endsWith(".chatgpt.site");
}
const noStore={"Cache-Control":"no-store","X-Content-Type-Options":"nosniff"};
const missing=()=>new Response("Publication not found",{status:404,headers:{...noStore,"X-Robots-Tag":"noindex"}});
export async function routeHostname(request:Request,config:{base:string;origin:string},requestFetch:typeof fetch=fetch):Promise<Response|{rewrite:string}|null>{
  // Forwarded-host headers are caller-controlled on some deployments. Routing
  // uses the actual Host header and an exact verified database binding instead.
  const host=normalizedHost(request.headers.get("host")||new URL(request.url).host);
  if(!host)return missing();
  if(platformHost(host,config.origin))return null;
  const url=new URL(request.url),path=url.pathname;
  if(path.startsWith("/_next/")||path.startsWith("/fonts/")||path==="/favicon.ico")return null;
  const response=await requestFetch(config.base+"/hosts/"+encodeURIComponent(host),{cache:"no-store",signal:AbortSignal.timeout(8000)});
  if(response.status===404)return missing();if(!response.ok)return new Response("Hostname lookup temporarily unavailable",{status:503,headers:noStore});
  const binding=await response.json() as PublicHost;
  if(binding.hostname!==host||!uuid.test(binding.space_id))return missing();
  if(path==="/.well-known/unsite-host")return Response.json({space_id:binding.space_id,hostname:host,probe_token:binding.probe_token},{headers:{...noStore,"X-Robots-Tag":"noindex"}});
  if(!binding.routable)return missing();
  if(/^\/[a-f0-9]{64}\.txt$/.test(path)){
    const key=path.slice(1,-4),file=await requestFetch(config.base+"/hosts/"+encodeURIComponent(host)+"/keys/"+key,{cache:"no-store",signal:AbortSignal.timeout(8000)});
    if(!file.ok)return missing();
    if((await file.text()).trim()!==key)return missing();
    return new Response(key,{headers:{...noStore,"Content-Type":"text/plain; charset=utf-8","X-Robots-Tag":"noindex"}});
  }
  if(path==="/robots.txt")return new Response("User-agent: *\nAllow: /\nDisallow: /account/\nDisallow: /auth/\nDisallow: /demo\nSitemap: https://"+host+"/sitemap.xml\n",{headers:{...noStore,"Content-Type":"text/plain"}});
  if(path==="/sitemap.xml"){
    const escape=(s:string)=>s.replace(/&/g,"&amp;").replace(/</g,"&lt;").replace(/"/g,"&quot;");
    const records:{id:string}[]=[];
    if(binding.published){for(let offset=0;offset<1000;offset+=100){
      const r=await requestFetch(config.base+"/v2/"+binding.space_id+"/records?limit=100&offset="+offset+"&release="+binding.release_id,{cache:"no-store",signal:AbortSignal.timeout(8000)});
      if(!r.ok)return new Response("Sitemap changed or is unavailable",{status:503,headers:noStore});
      const data=await r.json() as {records:{id:string}[];total:number};records.push(...data.records);if(offset+100>=data.total)break;
    }}
    const urls=binding.published?["https://"+host+"/",...records.map(r=>"https://"+host+"/records/"+r.id)]:[];
    return new Response('<?xml version="1.0" encoding="UTF-8"?><urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">'+urls.map(u=>"<url><loc>"+escape(u)+"</loc></url>").join("")+"</urlset>",{headers:{...noStore,"Content-Type":"application/xml"}});
  }
  if(!binding.published)return missing();
  if(path==="/"&&["GET","HEAD"].includes(request.method))return {rewrite:"/p/"+binding.space_id+url.search};
  if(path.startsWith("/records/")&&uuid.test(path.slice(9))&&["GET","HEAD"].includes(request.method))return {rewrite:"/p/"+binding.space_id+path+url.search};
  if(path==="/p/"+binding.space_id||path.startsWith("/p/"+binding.space_id+"/records/")){
    const target=path.slice(("/p/"+binding.space_id).length)||"/";
    if(target!=="/"&&!uuid.test(target.slice(9)))return missing();
    return Response.redirect("https://"+host+target+url.search,307);
  }
  const alias=path==="/llms.txt"||path==="/openapi.json"||path==="/index.md"||path==="/mcp"?path.slice(1):path.startsWith("/api/")?path.slice(5):"";
  if(!/^(manifest\.json|profile|authority|resources|search|records(?:\/[0-9a-f-]{36})?|bundle\.json|openapi\.json|llms\.txt|index\.md|catalog\.md|topics|mcp)$/.test(alias))return missing();
  if(!["GET","HEAD","OPTIONS"].includes(request.method)&&!(request.method==="POST"&&["search","mcp"].includes(alias)))return new Response(null,{status:405,headers:noStore});
  const headers=new Headers();for(const name of ["accept","content-type","if-none-match","mcp-protocol-version","origin"])if(request.headers.has(name))headers.set(name,request.headers.get(name)!);
  let body:Uint8Array|undefined;
  if(request.method==="POST"){
    const reader=request.body?.getReader(),parts:Uint8Array[]=[];let size=0;
    if(reader)try{for(;;){const part=await reader.read();if(part.done)break;size+=part.value.length;if(size>32768)return new Response(null,{status:413,headers:noStore});parts.push(part.value);}}finally{await reader.cancel();}
    body=new Uint8Array(size);let offset=0;for(const part of parts){body.set(part,offset);offset+=part.length;}
  }
  const api=await requestFetch(config.base+"/v2/"+binding.space_id+"/"+alias+url.search,{method:request.method,headers,body:body as BodyInit|undefined,redirect:"error",cache:"no-store",signal:AbortSignal.timeout(35000)});
  const publicHeaders=new Headers(api.headers);publicHeaders.delete("set-cookie");publicHeaders.set("Cache-Control","no-store");
  return new Response(api.body,{status:api.status,headers:publicHeaders});
}
