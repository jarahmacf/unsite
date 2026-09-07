import type {Metadata} from "next";
import Link from "next/link";
import {getPublicProfile,getPublicRecord,safeJsonLd} from "@/lib/production/public-delivery";
import {publicRuntime} from "@/lib/production/supabase";
import {contextOf} from "@/lib/production/knowledge";
import {PublicationFrame,PublicRecordBody} from "@/components/unsite/publication";
import "../../../../publication.css";
export const dynamic="force-dynamic";
type Props={params:Promise<{id:string;recordId:string}>};
export async function generateMetadata({params}:Props):Promise<Metadata>{
  const {id,recordId}=await params,p=await getPublicProfile(id),r=await getPublicRecord(id,recordId,p.release_id),url=p.canonical_url+"/records/"+recordId;
  return {title:r.title+" | "+p.name,description:contextOf(r.context).summary||r.text.slice(0,160),alternates:{canonical:url},robots:{index:true,follow:true},openGraph:{title:r.title,description:contextOf(r.context).summary,url,type:"article"}};
}
export default async function RecordPage({params}:Props){
  const {id,recordId}=await params,p=await getPublicProfile(id),r=await getPublicRecord(id,recordId,p.release_id),base=publicRuntime().base+"/v2/"+id;
  const metadata={"@context":"https://schema.org","@type":"CreativeWork","@id":p.canonical_url+"/records/"+recordId,name:r.title,text:r.text,datePublished:p.published_at,publisher:{"@id":p.canonical_url+"#entity"},isPartOf:{"@id":p.canonical_url}};
  return <PublicationFrame profile={p} base={base}><script type="application/ld+json" dangerouslySetInnerHTML={{__html:safeJsonLd(metadata)}}/><Link className="up-back" href={p.canonical_url}>← {p.name}</Link><article><h1>{r.title}</h1><PublicRecordBody record={r} publicationPath={p.canonical_url}/></article><div className="up-links"><a href={base+"/records/"+recordId}>Read as JSON</a><a href={base+"/records/"+recordId+"?format=md"}>Read as Markdown</a></div></PublicationFrame>;
}
