import {env} from "./runtime-env";
import { createServerClient, parseCookieHeader, serializeCookieHeader } from "@supabase/ssr";
import { z } from "zod";
export class AppError extends Error { constructor(public status:number,message:string){super(message);} }
export function runtime() {
  const e=env as unknown as Record<string,string|undefined>;
  const url=e.UNSITE_SUPABASE_URL,key=e.UNSITE_SUPABASE_PUBLISHABLE_KEY;
  if(!url||!key)throw new AppError(503,"Account services are not configured.");
  return {url,key,origin:e.UNSITE_APP_ORIGIN||"",workerToken:e.UNSITE_WORKER_TOKEN||"",workerGatewayKey:e.UNSITE_WORKER_GATEWAY_KEY||"",workerUrl:url+"/functions/v1/unsite-worker",publicBase:url+"/functions/v1/unsite/v2"};
}
export function requestClient(request:Request) {
  const config=runtime(),headers=new Headers({"Cache-Control":"private, no-store","X-Content-Type-Options":"nosniff"});
  const supabase=createServerClient(config.url,config.key,{
    cookieOptions:{httpOnly:true,secure:new URL(request.url).protocol==="https:",sameSite:"lax",path:"/"},
    cookies:{getAll:()=>parseCookieHeader(request.headers.get("cookie")||"").map(c=>({name:c.name,value:c.value||""})),setAll(cookies){for(const c of cookies)headers.append("Set-Cookie",serializeCookieHeader(c.name,c.value,c.options));}},
  });
  return {supabase,headers,config};
}
export type AppContext=ReturnType<typeof requestClient>;
export function writeGuard(request:Request) {
  if(request.method==="GET"||request.method==="HEAD")return;
  const origin=request.headers.get("origin");
  if(origin&&origin!==new URL(request.url).origin)throw new AppError(403,"Use your Unsite workspace to make this change.");
  if(!request.headers.get("content-type")?.includes("application/json"))throw new AppError(415,"Send a JSON request.");
}
export async function readJson(request:Request) {
  if(Number(request.headers.get("content-length")||0)>1000000)throw new AppError(413,"This request is too large.");
  const raw=await request.text();
  if(new TextEncoder().encode(raw).length>1000000)throw new AppError(413,"This request is too large.");
  try{return JSON.parse(raw);}catch{throw new AppError(400,"The request could not be read.");}
}
export function apiError(error:unknown,headers?:Headers) {
  const h=headers||new Headers({"Cache-Control":"private, no-store"});
  const status=error instanceof AppError?error.status:error instanceof z.ZodError?400:503;
  const message=error instanceof AppError?error.message:error instanceof z.ZodError?error.issues.slice(0,2).map(i=>i.message).join(" "):"We couldn’t complete this request. Your saved work is safe.";
  if(status===503)console.error("Unsite application request failed",error instanceof Error?error.message:"Unknown failure");
  return Response.json({error:message},{status,headers:h});
}
export function databaseError(error:{code?:string;message:string}|null) {
  if(!error)return;
  const known=["Invitation is unavailable for this account","Invitation is unavailable","Invitation has expired","Workspace member limit reached","This person already has access","Too many pending invitations","Owner access cannot be changed here","The workspace owner cannot leave","Member not found","Choose editor or viewer access","Invitation request already exists","Review the collection AI disclosure","Finish or stop the active collection run","Select one to eight source versions","Select each source version once","Source not found or upload incomplete","Collection knowledge limit reached","Collection run not found","Collection run is already complete","Only a paused collection run can resume","Review the retry notice","Collection run is not ready for review","Collection verification is incomplete","Review the verification concerns","Access denied","Workspace not found","Record changed","Source not found","Candidate not found","Upload is not complete","Workspace limit reached","No approved content","Review the publication","Review the AI disclosure","Job is already running","Request already exists"];
  const message=known.find(m=>error.message.includes(m));
  if(message)throw new AppError(message==="Access denied"?403:message==="Record changed"?409:400,message+".");
  throw new AppError(503,"Your request could not be saved. Please try again.");
}
