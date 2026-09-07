import type {KnowledgeContext, SuggestedLink} from "./knowledge.ts";
import type {KnowledgeFields, RecordKind} from "./types.ts";
import {terms,foldWord} from "./retrieval.ts";

export const COLLECTION_DISCLOSURE_VERSION="openai-collection-preparation-2026-09-05";
export const COLLECTION_LIMITS={sources:8,segments:80,segmentCharacters:12000,requests:200,batchItems:20,batchSegments:4,batchCharacters:90000} as const;
export type Segment={id:string;space_id:string;source_version_id:string;source_id?:string;ordinal:number;start_char:number;end_char:number;text:string;locator:string};
export type SourceItem={id:string;kind:RecordKind;title:string;text:string;fields:KnowledgeFields;context:KnowledgeContext;suggested_links:SuggestedLink[];warnings:string[];evidence:{segment_id:string;source_version_id:string;quote:string;locator:string}[]};
export type FrozenRecord={id:string;revision:number;title:string;text:string;kind:RecordKind;fields:KnowledgeFields;context:KnowledgeContext;links?:unknown[];source_ids?:string[]};
export type CollectionBatch={source_items:string[];record_ids:string[];omitted_record_ids?:string[]};
export type Verdict={verdict:"supported"|"needs_review"|"unsupported";issues:string[]};
export type Proposal=Omit<SourceItem,"id">&{source_items:string[];suggested_record_id:string|null;suggested_record_revision:number|null;change_reason:string};
export type Curated={proposals:Proposal[];unresolved:{source_item_id:string;reason:string}[];summary:string};
export type CollectionRun={id:string;space_id:string;goal:string;status:"waiting"|"running"|"blocked"|"completed"|"cancelled";stage:string;max_requests:number;source_revision:number;error_code:string|null;error_message:string|null;created_at:string;updated_at:string;authorized_at:string;revoked_at:string|null};
export type CollectionTask={id:string;run_id:string;space_id:string;stage:"extract"|"plan"|"curate"|"verify";ordinal:number;status:string;attempts:number;error_message:string|null;input:Record<string,unknown>;output:unknown;lease_token:string};

const words=(s:string)=>new Set(terms(s,8000).map(foldWord));
const labels=(v:SourceItem|FrozenRecord)=>words([v.title,...v.context.aliases,...v.context.topics].join(" "));
const content=(v:SourceItem|FrozenRecord)=>words([v.context.summary,v.context.attribution,v.context.type_label,v.text,JSON.stringify(v.fields)].join(" "));
function overlap(a:Set<string>,b:Set<string>){let n=0;for(const v of a)if(b.has(v))n++;return n/Math.max(1,Math.min(a.size,b.size));}

/** A bounded routing heuristic, never an identity or merge decision. Every item is assigned once. */
export function planCollection(items:SourceItem[],segments:Segment[],records:FrozenRecord[]):CollectionBatch[]{
  if(new Set(items.map(i=>i.id)).size!==items.length)throw new Error("Repeated source item identifiers");
  const segmentMap=new Map(segments.map(s=>[s.id,s])),remaining=[...items],batches:CollectionBatch[]=[];
  const recordSignals=new Map(records.map(r=>[r.id,{labels:labels(r),content:content(r)}]));
  while(remaining.length){
    const selected:SourceItem[]=[],used=new Set<string>();let size=0;
    const first=remaining[0],seed=labels(first);
    remaining.sort((a,b)=>overlap(seed,labels(b))-overlap(seed,labels(a))||a.id.localeCompare(b.id));
    for(let i=0;i<remaining.length&&selected.length<COLLECTION_LIMITS.batchItems;){
      const item=remaining[i],ids=[...new Set(item.evidence.map(e=>e.segment_id))];
      if(ids.some(id=>!segmentMap.has(id)))throw new Error("Missing canonical evidence segment");
      const added=ids.filter(id=>!used.has(id));
      const cost=JSON.stringify(item).length+added.reduce((sum,id)=>sum+segmentMap.get(id)!.text.length,0);
      if(selected.length&&(used.size+added.length>COLLECTION_LIMITS.batchSegments||size+cost>COLLECTION_LIMITS.batchCharacters)){i++;continue;}
      if(used.size+added.length>COLLECTION_LIMITS.batchSegments||size+cost>COLLECTION_LIMITS.batchCharacters)throw new Error("A source suggestion is too large for one curation task. Use smaller source sections.");
      selected.push(item);remaining.splice(i,1);for(const id of added)used.add(id);size+=cost;
    }
    const labelTerms=new Set(selected.flatMap(i=>[...labels(i)])),contentTerms=new Set(selected.flatMap(i=>[...content(i)]));
    const sourceIds=new Set(selected.flatMap(i=>i.evidence.map(e=>segmentMap.get(e.segment_id)?.source_id).filter((id):id is string=>!!id)));
    let recordSize=0;
    const omitted:string[]=[];
    const related=records.map(r=>({r,score:overlap(labelTerms,recordSignals.get(r.id)!.labels)*4+overlap(contentTerms,recordSignals.get(r.id)!.content)+(r.source_ids?.some(id=>sourceIds.has(id))?10:0)})).filter(x=>x.score>0).sort((a,b)=>b.score-a.score||a.r.id.localeCompare(b.r.id)).filter(({r})=>{const n=JSON.stringify(r).length;if(recordSize+n>55000){omitted.push(r.id);return false;}recordSize+=n;return true;});
    batches.push({source_items:selected.map(i=>i.id),record_ids:related.map(x=>x.r.id),...(omitted.length?{omitted_record_ids:omitted}:{})});
  }
  return batches;
}

export function assertCoverage(expected:string[],covered:string[],allowRepeated=false){
  const known=new Set(expected),seen=new Set(covered);
  if(expected.length!==known.size||seen.size!==known.size||covered.some(id=>!known.has(id))||(!allowRepeated&&seen.size!==covered.length))throw new Error("Every source item must be accounted for, with no invented identifiers.");
}
export const normalizeEvidence=(s:string)=>s.replace(/\s+/g," ").trim();
export function assertEvidence(evidence:SourceItem["evidence"],segments:Segment[]){
  if(!Array.isArray(evidence)||evidence.length<1||evidence.length>10)throw new Error("A proposal needs one to ten source quotes.");
  for(const e of evidence){const s=segments.find(s=>s.id===e.segment_id);if(!s||e.source_version_id!==s.source_version_id||typeof e.quote!=="string"||normalizeEvidence(e.quote).length<12||e.quote.length>3000||!normalizeEvidence(s.text).includes(normalizeEvidence(e.quote)))throw new Error("A quote does not match its canonical source segment.");}
}
