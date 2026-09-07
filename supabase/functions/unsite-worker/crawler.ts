import {normalizeWebsite,publicAddress,robotsAllows} from "../../../lib/scan-utils.ts";
import {ProcessingError} from "./parser.ts";
export async function boundedText(response:Response,max:number){
  if(Number(response.headers.get("content-length")||0)>max)throw new ProcessingError("SOURCE_TOO_LARGE","This page is too large to import.");
  const reader=response.body?.getReader();if(!reader)return "";
  const parts:Uint8Array[]=[];let size=0;
  try{while(true){const {done,value}=await reader.read();if(done)break;size+=value.length;if(size>max)throw new ProcessingError("SOURCE_TOO_LARGE","This page is too large to import.");parts.push(value);}}finally{await reader.cancel();}
  const buffer=new Uint8Array(size);let offset=0;for(const p of parts){buffer.set(p,offset);offset+=p.length;}return new TextDecoder().decode(buffer);
}
export async function importPage(input:string,deps:{resolve:(host:string)=>Promise<string[]>;html:(text:string)=>string;fetch:typeof fetch}){
  async function checked(url:URL){
    const safe=normalizeWebsite(url.href),addresses=await deps.resolve(safe.hostname);
    if(!addresses.length||addresses.some(a=>!publicAddress(a)))throw new ProcessingError("PRIVATE_ADDRESS","Import a page on a public website.");
    return safe;
  }
  let url:URL;try{url=normalizeWebsite(input);}catch{throw new ProcessingError("INVALID_URL","Use a public HTTPS page URL.");}
  const allowedOrigins=new Set<string>();
  for(let redirect=0;redirect<5;redirect++){
    url=await checked(url);
    if(!allowedOrigins.has(url.origin)){
      const robots=await deps.fetch(new URL("/robots.txt",url),{redirect:"manual",headers:{"User-Agent":"UnsiteBot/1.0"},signal:AbortSignal.timeout(12000)});
      if(robots.status!==404&&robots.status!==410){
        if(!robots.ok)throw new ProcessingError("ROBOTS_UNAVAILABLE","The website's crawling rules could not be verified. Upload a document or paste the text instead.");
        const rules=await boundedText(robots,512000);
        if(!robotsAllows(rules,url,"unsitebot"))throw new ProcessingError("ROBOTS_DENIED","This website does not allow this page to be imported. Upload content you own instead.");
      }
      allowedOrigins.add(url.origin);
    }
    const response=await deps.fetch(url,{redirect:"manual",headers:{"User-Agent":"UnsiteBot/1.0","Accept":"text/html,text/plain"},signal:AbortSignal.timeout(20000)});
    if(response.status>=300&&response.status<400){const next=response.headers.get("location");await response.body?.cancel();if(!next)break;url=new URL(next,url);allowedOrigins.delete(url.origin);continue;}
    if(!response.ok)throw new ProcessingError("PAGE_UNAVAILABLE",`The website returned ${response.status}. Upload the content or try again later.`,response.status>=500?"retry":"failed");
    const type=response.headers.get("content-type")||"";
    if(!/text\/(html|plain)/i.test(type))throw new ProcessingError("UNSUPPORTED_PAGE","Import an HTML page, or upload this document as a file.");
    const raw=await boundedText(response,2500000);
    const text=type.includes("html")?deps.html(raw):raw;
    if(text.trim().length<80)throw new ProcessingError("NO_PAGE_TEXT","This page did not expose enough readable text. Pages rendered entirely with JavaScript need a document or text import.");
    return text;
  }
  throw new ProcessingError("REDIRECT_LIMIT","This page redirects too many times. Use its final public address.");
}
