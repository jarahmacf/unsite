import Link from "next/link";
import type {ReactNode} from "react";
import type {PublicProfile} from "@/lib/production/public-delivery";
import type {PublishedRecord} from "@/lib/production/release";
import {contextOf,entryType,framingLabels,relationLabels,statusLabels} from "@/lib/production/knowledge";

export function PublicationFrame({profile,base,children}:{profile:PublicProfile;base:string;children:ReactNode}){
  const verified=profile.authority?.status==="verified"&&!!profile.authority.expires_at&&Date.parse(profile.authority.expires_at)>Date.now();
  return <div className="unsite-public"><header className="up-header"><Link href="/directory" className="up-brand">unsite.</Link><nav aria-label="Publication resources"><a href={base+"/index.md"}>Markdown</a><a href={base+"/openapi.json"}>API</a><a href={base+"/mcp"}>MCP</a></nav></header>
    <main className="up-main">{children}</main>
    <footer className="up-footer"><strong>Published by {profile.name}</strong><p>Release {profile.release_id} · Published <time dateTime={profile.published_at}>{new Date(profile.published_at).toISOString().slice(0,10)}</time></p>
      <p>{verified?`Control of ${profile.authority!.domain} was verified by DNS. This confirms domain control; it is not independent verification of every claim.`:"This publication is owner approved. Its official domain has not been verified."} <a href={base+"/authority"}>View verification</a></p>
      <p>Read the context and source dates of each entry. Publication dates describe the release, not when every statement was true.</p></footer>
  </div>;
}
export function PublicRecordBody({record,publicationPath}:{record:PublishedRecord;publicationPath:string}){
  const c=contextOf(record.context);
  return <><div className="up-context"><span>{entryType(record)}</span>{c.framing&&c.framing!=="unspecified"&&<span>{framingLabels[c.framing]}</span>}{c.status!=="unspecified"&&<span>{statusLabels[c.status]}</span>}{c.as_of&&<span>As of <time dateTime={c.as_of}>{c.as_of}</time></span>}</div>
    {c.attribution&&<p className="up-muted">Perspective: {c.attribution}</p>}{c.summary&&<p className="up-lead">{c.summary}</p>}
    <div className="up-prose">{record.text}</div>
    {Object.keys(record.fields).length>0&&<dl className="up-fields">{Object.entries(record.fields).map(([k,v])=><div key={k}><dt>{k}</dt><dd>{v===null?"Unknown":String(v)}</dd></div>)}</dl>}
    {c.topics.length>0&&<p className="up-muted">Topics: {c.topics.join(", ")}</p>}
    {record.source_url&&<p><a href={record.source_url} rel="nofollow noopener noreferrer">Publisher-listed source</a></p>}
    {!!record.links?.length&&<section className="up-related"><h2>Related knowledge</h2><ul>{record.links.map(l=><li key={l.relation+l.target_id}>{relationLabels[l.relation]}: <Link href={publicationPath+"/records/"+l.target_id}>{l.target_id}</Link></li>)}</ul></section>}
  </>;
}
