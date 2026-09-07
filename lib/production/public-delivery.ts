import {cache} from "react";
import {notFound} from "next/navigation";
import {publicRuntime} from "./supabase";
import type {Authority} from "./presence";
import type {PublishedRecord,Snapshot} from "./release";

export const publicId=/^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;
export type PublicProfile=Omit<Snapshot,"records">&{release_id:string;published_at:string;authority:Authority|null;canonical_url:string;discovery?:{google_token?:string;bing_token?:string}|null};
export type DirectoryEntry={id:string;name:string;description:string;release_id:string;published_at:string};
export async function publicRead<T>(path:string):Promise<T>{
  const response=await fetch(publicRuntime().base+path,{cache:"no-store",signal:AbortSignal.timeout(20000),headers:{Accept:"application/json"}});
  if(response.status===404)notFound();
  if(!response.ok)throw new Error("Published knowledge is temporarily unavailable. Please retry.");
  return response.json();
}
export const getPublicProfile=cache(async(id:string)=>{if(!publicId.test(id))notFound();return publicRead<PublicProfile>(`/v2/${id}/profile`);});
export const getPublicRecord=cache(async(id:string,recordId:string,releaseId:string)=>{if(!publicId.test(id)||!publicId.test(recordId))notFound();return publicRead<PublishedRecord>(`/v2/${id}/records/${recordId}?release=${releaseId}`);});
export const getPublicRecords=cache(async(id:string,releaseId:string,offset=0)=>publicRead<{records:PublishedRecord[];total:number}>(`/v2/${id}/records?release=${releaseId}&offset=${offset}&limit=100`));
export function publicAddress(id:string){return publicRuntime().origin+"/p/"+id;}
export function safeJsonLd(data:unknown){return JSON.stringify(data).replace(/</g,"\\u003c").replace(/>/g,"\\u003e").replace(/&/g,"\\u0026");}
