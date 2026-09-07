import Link from "next/link";
import type {Metadata} from "next";
import {publicRead,type DirectoryEntry} from "@/lib/production/public-delivery";
import {publicRuntime} from "@/lib/production/supabase";
import "../publication.css";
export const dynamic="force-dynamic";
export function generateMetadata():Metadata{return {title:"Published knowledge | Unsite",description:"Explore owner-approved publications on Unsite.",alternates:{canonical:publicRuntime().origin+"/directory"}};}
export default async function Directory({searchParams}:{searchParams:Promise<{page?:string}>}){
  const query=await searchParams,page=Math.max(1,Math.min(10000,Number.isInteger(Number(query.page))?Number(query.page):1));
  const data=await publicRead<{items:DirectoryEntry[];total:number}>("/directory?offset="+(page-1)*100+"&limit=100");
  return <div className="unsite-public"><header className="up-header"><Link className="up-brand" href="/">unsite.</Link><Link href="/">Your workspace</Link></header><main className="up-main"><div className="up-eyebrow">Public directory</div><h1>Knowledge, from the source.</h1><p className="up-lead">Explore publications approved by their owners. Each publication explains its source context and domain verification.</p><div className="up-records">{data.items.map(p=><article key={p.id}><h2><Link href={"/p/"+p.id}>{p.name}</Link></h2><p>{p.description}</p></article>)}</div>{!data.items.length&&<p className="up-muted">{page===1?"No publications are public yet.":"There are no publications on this page."}</p>}<nav className="up-pagination" aria-label="Directory pages">{page>1&&<Link href={"/directory?page="+(page-1)}>Previous</Link>}{page*100<data.total&&<Link href={"/directory?page="+(page+1)}>Next</Link>}</nav></main></div>;
}
