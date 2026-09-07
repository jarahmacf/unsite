import type {Metadata} from "next";
import Link from "next/link";
import {headers} from "next/headers";
import {normalizedHost} from "@/lib/production/host-routing";
import {getPublicProfile,getPublicRecords,safeJsonLd} from "@/lib/production/public-delivery";
import {publicRuntime} from "@/lib/production/supabase";
import {entityMetadata} from "@/lib/production/presence";
import {contextOf,entryType} from "@/lib/production/knowledge";
import {PublicationFrame} from "@/components/unsite/publication";
import "../../publication.css";

export const dynamic="force-dynamic";
type Props={params:Promise<{id:string}>;searchParams:Promise<{page?:string}>};
export async function generateMetadata({params}:Props):Promise<Metadata>{
  const {id}=await params,p=await getPublicProfile(id),url=p.canonical_url;
  const ownHost=normalizedHost((await headers()).get("host")||"")===new URL(url).hostname;
  return {title:p.name+" | Unsite",description:p.description,alternates:{canonical:url},robots:{index:true,follow:true},verification:ownHost?{google:p.discovery?.google_token||undefined,other:p.discovery?.bing_token?{"msvalidate.01":p.discovery.bing_token}:undefined}:undefined,openGraph:{title:p.name,description:p.description,url,type:"website"}};
}
export default async function PublicPage({params,searchParams}:Props){
  const {id}=await params,p=await getPublicProfile(id),query=await searchParams;
  const page=Math.max(1,Math.min(100,Number.isInteger(Number(query.page))?Number(query.page):1));
  const data=await getPublicRecords(id,p.release_id,(page-1)*100),path=p.canonical_url,base=publicRuntime().base+"/v2/"+id;
  const metadata=entityMetadata({...p,records:[]},p.canonical_url);
  return <PublicationFrame profile={p} base={base}><script type="application/ld+json" dangerouslySetInnerHTML={{__html:safeJsonLd(metadata)}}/>
    <div className="up-eyebrow">Publisher-approved knowledge</div><h1>{p.name}</h1><p className="up-lead">{p.description}</p>
    {p.publisher?.official_url&&<p><a href={p.publisher.official_url} rel="me nofollow noopener noreferrer">Official website</a></p>}
    {!!p.publisher?.aliases.length&&<p className="up-muted">Also known as {p.publisher.aliases.join(", ")}</p>}
    <section className="up-section"><div className="up-section-heading"><h2>Knowledge</h2><span>{data.total} entries</span></div><div className="up-records">{data.records.map(r=><article key={r.id}><span className="up-eyebrow">{entryType(r)}</span><h3><Link href={path+"/records/"+r.id}>{r.title}</Link></h3><p>{contextOf(r.context).summary||r.text.slice(0,260)+(r.text.length>260?"…":"")}</p>{contextOf(r.context).as_of&&<small>As of {r.context!.as_of}</small>}</article>)}</div>
      <nav className="up-pagination" aria-label="Knowledge pages">{page>1&&<Link href={path+"?page="+(page-1)}>Previous page</Link>}{page*100<data.total&&<Link href={path+"?page="+(page+1)}>Next page</Link>}</nav></section>
    {!!p.resources?.length&&<section className="up-section"><h2>Resources</h2><p className="up-muted">Public links selected by the publisher. Linked resources may change independently of this release.</p><div className="up-records">{p.resources.map(r=><article key={r.id}><span className="up-eyebrow">{r.mime_type}{r.version_label?" · "+r.version_label:""}</span><h3><a href={r.url} rel="nofollow noopener noreferrer">{r.title}</a></h3><p>{r.description}</p>{r.as_of&&<small>As of {r.as_of}</small>}</article>)}</div></section>}
    <section className="up-section"><h2>For agents and applications</h2><p>Search and read complete, approved records through the public API. The read-only MCP server offers search, fetch, and resource discovery.</p><div className="up-links"><a href={base+"/llms.txt"}>Discovery index</a><a href={base+"/openapi.json"}>OpenAPI definition</a><a href={base+"/bundle.json"}>JSON bundle</a><a href={base+"/mcp"}>MCP endpoint</a></div></section>
  </PublicationFrame>;
}
