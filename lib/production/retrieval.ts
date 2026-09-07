import {contextOf,entryType,matchesType} from "./knowledge.ts";
import type {PublishedRecord,Snapshot} from "./release.ts";
const stop=new Set("a an the is are was were be been being to of for in on at by and or with from it this that these those what which who whom how when where why do does did can could would should tell me about please".split(" "));
export function terms(text:string,maxTerms=40){return [...new Set((text.normalize("NFKC").toLocaleLowerCase().match(/[\p{L}\p{N}]+/gu)||[]).filter(t=>t.length>1&&!stop.has(t)))].slice(0,maxTerms);}
const normalize=(text:string)=>text.normalize("NFKC").toLocaleLowerCase();
const synonymGroups=[["refund","reimbursement"],["price","pricing","cost"],["timetable","schedule"]];
export function foldWord(word:string){
  let value=normalize(word);
  if(/^[a-z]+$/.test(value)&&value.length>4){
    if(value.endsWith("ies"))value=value.slice(0,-3)+"y";
    else if(/(ches|shes|xes|sses)$/.test(value))value=value.slice(0,-2);
    else if(value.endsWith("s")&&!/(ss|us|is)$/.test(value))value=value.slice(0,-1);
  }
  return synonymGroups.find(group=>group.includes(value))?.[0]||value;
}
export function indexedQuery(query:string){return [...new Set(terms(query).flatMap(t=>{const word=foldWord(t);return synonymGroups.find(g=>g.includes(word))||[t];}))].join(" OR ");}
const words=(text:string)=>new Set((normalize(text).match(/[\p{L}\p{N}]+/gu)||[]).map(foldWord));
function passages(text:string){const parts:string[]=[];let start=0;while(start<text.length){let end=Math.min(start+1200,text.length);if(end<text.length){const boundary=text.lastIndexOf("\n",end);if(boundary>start+500)end=boundary;}parts.push(text.slice(start,end));start=end;}return parts.length?parts:[""];}
export type SearchHit={id:string;title:string;kind:string;summary:string;excerpt:string;matched_terms:string[];context:ReturnType<typeof contextOf>;fields:Record<string,unknown>;links:PublishedRecord["links"];revision:number;url?:string;markdown_url?:string};
export function searchKnowledge(snapshot:Snapshot,query:string,options:{limit?:number;kind?:string;type?:string;topic?:string;base?:string;release_id?:string;indexedMatches?:boolean}={}){
  const tokens=[...new Set(terms(query).map(foldWord))],limit=Math.min(20,Math.max(1,options.limit||8));
  if(!tokens.length)return {query,results:[] as SearchHit[],total:0,matched:false};
  const docs=snapshot.records.filter(r=>(!options.kind||r.kind===options.kind)&&(!options.type||matchesType(r,options.type))&&(!options.topic||contextOf(r.context).topics.some(t=>normalize(t)===normalize(options.topic!))));
  const corpus=docs.map(r=>{const c=contextOf(r.context);return {r,c,head:words([r.title,entryType(r),c.attribution||"",...c.aliases,...c.topics,c.summary].join(" ")),body:words(r.text+" "+Object.entries(r.fields).map(([k,v])=>k+" "+(v===null?"unknown":String(v))).join(" "))};});
  const idf=new Map(tokens.map(t=>[t,Math.log(1+(corpus.length+1)/(1+corpus.filter(d=>(d.head.has(t)||d.body.has(t))).length))]));
  const ranked=corpus.map(({r,c,head,body})=>{
    const matched=tokens.filter(t=>(head.has(t)||body.has(t)));
    const score=matched.reduce((n,t)=>n+(idf.get(t)||1)*(head.has(t)?4:1),0)+(normalize(r.title)===normalize(query.trim())?15:0);
    const fragments=passages(r.text).map((p,i)=>{const passageWords=words(p);return {p,i,score:tokens.reduce((n,t)=>n+(passageWords.has(t)?idf.get(t)||1:0),0)};}).sort((a,b)=>b.score-a.score||a.i-b.i);
    const fragment=fragments[0]?.p||"";const first=tokens.map(t=>normalize(fragment).indexOf(t)).filter(i=>i>=0).sort((a,b)=>a-b)[0]??0;
    const start=Math.max(0,first-160),excerpt=(start?"…":"")+fragment.slice(start,start+780)+(fragment.length>start+780?"…":"");
    const pin=options.release_id?"&release="+encodeURIComponent(options.release_id):"";
    const url=options.base?`${options.base}/records/${r.id}${options.release_id?"?release="+encodeURIComponent(options.release_id):""}`:undefined;
    return {score,hit:{id:r.id,title:r.title,kind:r.kind,summary:c.summary,excerpt,matched_terms:matched,context:c,fields:r.fields,links:r.links||[],revision:r.revision,...(url?{url,markdown_url:`${options.base}/records/${r.id}?format=md${pin}`}:{})}};
  }).filter(x=>x.score>0||options.indexedMatches).sort((a,b)=>b.score-a.score||(options.indexedMatches?0:a.hit.id.localeCompare(b.hit.id)));
  return {query,results:ranked.slice(0,limit).map(x=>x.hit),total:ranked.length,matched:ranked.length>0};
}
export type RetrievalCase={id:string;question:string;expected_record_id:string|null;expectation:"find"|"no_match"};
export function runRetrievalCases(snapshot:Snapshot,cases:RetrievalCase[]){return cases.map(c=>{const result=searchKnowledge(snapshot,c.question,{limit:5});const available=!c.expected_record_id||snapshot.records.some(r=>r.id===c.expected_record_id);return {...c,passed:available&&(c.expectation==="no_match"?!result.matched:result.results.some(r=>r.id===c.expected_record_id)),expected_available:available,returned_ids:result.results.map(r=>r.id),returned_titles:result.results.map(r=>r.title)};});}
export function inspectKnowledge(snapshot:Snapshot){
  const records=snapshot.records,ids=new Set(records.map(r=>r.id));
  const check=(id:string,label:string,affected:string[],detail:string)=>({id,label,status:affected.length?"attention" as const:"pass" as const,record_ids:affected,detail});
  const titleCounts=new Map<string,number>();for(const r of records)titleCounts.set(normalize(r.title),(titleCounts.get(normalize(r.title))||0)+1);
  const names=new Map<string,string[]>();for(const r of records){const key=normalize(entryType(r))+":"+normalize(r.title.trim());names.set(key,[...names.get(key)||[],r.id]);}
  return {record_count:records.length,relationship_count:records.reduce((n,r)=>n+(r.links?.length||0),0),topic_count:new Set(records.flatMap(r=>contextOf(r.context).topics)).size,checks:[
    check("overview","Collection introduction",snapshot.description.trim()?[]:[snapshot.id],snapshot.description.trim()?"An introduction explains what this collection covers.":"Add an introduction so an agent can orient itself."),
    check("summaries","Entry summaries",records.filter(r=>!contextOf(r.context).summary.trim()).map(r=>r.id),"Summaries help an agent select which complete entries to read."),
    check("framing","Content interpretation",records.filter(r=>(contextOf(r.context).framing||"unspecified")==="unspecified").map(r=>r.id),"Specify how to read the material when known: for example fiction, a viewpoint, source-reported information, or a procedure."),
    check("identities","Distinct entry names",[...names.values()].filter(v=>v.length>1).flat(),"Repeated names of the same content type may describe overlapping knowledge. Review before merging."),
    check("links","Valid relationships",records.filter(r=>r.links?.some(l=>!ids.has(l.target_id))).map(r=>r.id),"Relationships should resolve to entries included in this publication."),
    check("dates","Explicit knowledge dates",records.filter(r=>!["fiction","opinion","instruction","interpretation"].includes(contextOf(r.context).framing||"unspecified")&&!contextOf(r.context).as_of).map(r=>r.id),"Source-reported information may need a date. Editing and publication dates do not establish when it applied; add an as-of date only when relevant and known."),
    check("retrieval","Searchable entry titles",records.filter(r=>!terms(r.title).length||(titleCounts.get(normalize(r.title))||0)>5).map(r=>r.id),"Distinct searchable titles help select records. Use saved questions to test actual retrieval."),
  ]};
}
