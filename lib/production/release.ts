import {contextOf,entryType,framingLabels,relationLabels,type KnowledgeContext,type KnowledgeLink} from "./knowledge.ts";
import type {Publisher,PublicResource} from "./public-types.ts";
export type PublishedRecord={id:string;kind:string;title:string;text:string;fields:Record<string,unknown>;source_url?:string|null;revision:number;context?:KnowledgeContext;updated_at?:string;links?:KnowledgeLink[]};
export type Snapshot={schema_version:"2.0"|"2.1";id:string;name:string;kind:"person"|"business"|"project"|"collection";description:string;contact_email?:string|null;records:PublishedRecord[];publisher?:Publisher;resources?:PublicResource[]};
export type PublicRelease={id:string;space_id:string;revision:number;source_revision:number;published_at:string;data:Snapshot};
export const KINDS=["about","person","offering","project","faq","policy","location","general"] as const;
function recordFraming(r:PublishedRecord){
  const c=contextOf(r.context),line=(value:string)=>value.replace(/[\r\n]+/g," ");
  return ["Content type: "+line(entryType(r)),...(c.framing&&c.framing!=="unspecified"?["How to read this: "+framingLabels[c.framing]]:[]),...(c.attribution?["Perspective: "+line(c.attribution)]:[])].join("\n")+"\n\n";
}
export function recordMarkdown(r:PublishedRecord,base?:string,releaseId?:string){const c=contextOf(r.context);return `## ${r.title}\n\n${recordFraming(r)}${c.summary?c.summary+"\n\n":""}${r.text}\n${Object.keys(r.fields).length?"\n"+Object.entries(r.fields).map(([k,v])=>`- ${k}: ${v===null?"Unknown":String(v)}`).join("\n")+"\n":""}\nRecord: ${r.id} · revision ${r.revision}\n${c.status!=="unspecified"?`Knowledge status: ${c.status}\n`:""}${c.as_of?`Knowledge as of: ${c.as_of}\n`:""}${c.topics.length?`Topics: ${c.topics.join(", ")}\n`:""}${r.links?.length?"\nRelated records:\n"+r.links.map(l=>`- ${relationLabels[l.relation]}: ${base?`[${l.target_id}](${base}/records/${l.target_id}?format=md${releaseId?"&release="+releaseId:""})`:l.target_id}`).join("\n")+"\n":""}${r.source_url?`\nPublic source: ${r.source_url}\n`:""}`;}
export function releaseMarkdown(d:Snapshot,base?:string,releaseId?:string){return `# ${d.name}\n\n${d.description}\n${d.publisher?.official_url?`\nPublisher website: ${d.publisher.official_url}\n`:""}${d.contact_email?`\nContact: ${d.contact_email}\n`:""}\n${d.records.map(r=>recordMarkdown(r,base,releaseId)).join("\n")}\n${d.resources?.length?"## Publisher-approved resources\n\n"+d.resources.map(r=>`- [${r.title.replace(/[\[\]\r\n]/g," ")}](${r.url}): ${r.description}${r.as_of?" (as of "+r.as_of+")":""}`).join("\n")+"\n":""}`;}
export function releaseDiff(before:Snapshot|undefined,after:Snapshot){
  const old=new Map(before?.records.map(r=>[r.id,r])||[]),next=new Map(after.records.map(r=>[r.id,r]));
  const added=after.records.filter(r=>!old.has(r.id));
  const canonical=(value:unknown):string=>JSON.stringify(value,(_,v)=>v&&typeof v==="object"&&!Array.isArray(v)?Object.fromEntries(Object.entries(v).sort(([a],[b])=>a.localeCompare(b))):v);
  const changed=after.records.filter(r=>old.has(r.id)&&canonical(old.get(r.id))!==canonical(r));
  const removed=(before?.records||[]).filter(r=>!next.has(r.id));
  const profileChanged=!before||["name","kind","description","contact_email"].some(k=>String(before[k as keyof Snapshot]||"")!==String(after[k as keyof Snapshot]||""))||canonical(before.publisher||null)!==canonical(after.publisher||null);
  const resourcesChanged=canonical(before?.resources||[])!==canonical(after.resources||[]);
  return {added,changed,removed,profileChanged,resourcesChanged};
}
