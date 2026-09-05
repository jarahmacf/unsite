export const RELATIONS = ["related_to","part_of","created_by","depends_on","documents","supersedes"] as const;
export const KNOWLEDGE_STATES = ["unspecified","current","historical","uncertain"] as const;
export const FRAMINGS = ["unspecified","source_claim","opinion","fiction","instruction","interpretation","mixed"] as const;
export type Framing = typeof FRAMINGS[number];
export type Relation = typeof RELATIONS[number];
export type KnowledgeContext = {summary:string;aliases:string[];topics:string[];status:typeof KNOWLEDGE_STATES[number];as_of:string|null;type_label?:string;framing?:Framing;attribution?:string};
export type KnowledgeLink = {target_id:string;relation:Relation};
export type SuggestedLink = {target_title:string;relation:Relation;quote:string};
export const emptyContext = ():KnowledgeContext=>({summary:"",aliases:[],topics:[],status:"unspecified",as_of:null,type_label:"",framing:"unspecified",attribution:""});
export const relationLabels:Record<Relation,string>={related_to:"Related to",part_of:"Part of",created_by:"Created by",depends_on:"Depends on",documents:"Documents",supersedes:"Supersedes"};
export const statusLabels:Record<KnowledgeContext["status"],string>={unspecified:"Not specified",current:"Current",historical:"Historical",uncertain:"Uncertain"};
export const framingLabels:Record<Framing,string>={unspecified:"Not specified",source_claim:"Source-reported information",opinion:"Opinion or viewpoint",fiction:"Fiction or imagined scenario",instruction:"Instructions or procedure",interpretation:"Analysis or interpretation",mixed:"Mixed material"};
const legacyTypes:Record<string,string>={about:"Overview",person:"Person",offering:"Offering",project:"Project",faq:"Question & answer",policy:"Policy",location:"Location",general:"Knowledge"};
export function entryType(r:{kind:string;context?:Partial<KnowledgeContext>|null}){return r.context?.type_label?.trim()||legacyTypes[r.kind]||r.kind;}
export function matchesType(r:{kind:string;context?:Partial<KnowledgeContext>|null},label:string){return entryType(r).normalize("NFKC").toLowerCase()===label.trim().normalize("NFKC").toLowerCase();}
export function contextOf(value?:Partial<KnowledgeContext>|null):KnowledgeContext{return {...emptyContext(),...value};}
export function validContext(value:unknown):value is KnowledgeContext{
  if(!value||typeof value!=="object"||Array.isArray(value))return false;
  const v=value as KnowledgeContext;
  if(Object.keys(value).some(k=>!["summary","aliases","topics","status","as_of","type_label","framing","attribution"].includes(k)))return false;
  if(v.type_label!==undefined&&(typeof v.type_label!=="string"||v.type_label.length>100))return false;
  if(v.framing!==undefined&&!FRAMINGS.includes(v.framing))return false;
  if(v.attribution!==undefined&&(typeof v.attribution!=="string"||v.attribution.length>600))return false;
  const tags=(a:unknown)=>Array.isArray(a)&&a.length<=20&&a.every(x=>typeof x==="string"&&x.trim().length>0&&x.length<=100);
  return typeof v.summary==="string"&&v.summary.length<=1200&&tags(v.aliases)&&tags(v.topics)&&KNOWLEDGE_STATES.includes(v.status)&&(v.as_of===null||typeof v.as_of==="string"&&/^\d{4}-\d{2}-\d{2}$/.test(v.as_of)&&!isNaN(Date.parse(v.as_of))&&new Date(v.as_of).toISOString().slice(0,10)===v.as_of);
}
export type Comparable={id:string;kind:string;title:string;text:string;fields:Record<string,unknown>;context?:KnowledgeContext;revision:number};
export function differingFields(a:Comparable,b:Comparable){
  const normalize=(v:unknown)=>v===null?"null":typeof v+":"+String(v).trim().toLocaleLowerCase();
  return Object.keys(a.fields).filter(k=>Object.hasOwn(b.fields,k)&&normalize(a.fields[k])!==normalize(b.fields[k])).map(key=>({key,incoming:a.fields[key],existing:b.fields[key]}));
}

export function combineMaterial(existing:Pick<Comparable,"kind"|"title"|"text"|"context">,incoming:Pick<Comparable,"kind"|"title"|"text"|"context">){
  const section=(r:typeof existing)=>{
    const c=contextOf(r.context),line=(s:string)=>s.replace(/[\r\n]+/g," ");
    return ["### "+line(r.title),"","Content type: "+line(entryType(r)),"How to read this: "+framingLabels[c.framing||"unspecified"],
      ...(c.attribution?["Perspective: "+line(c.attribution)]:[]),...(c.as_of?["Applies as of: "+c.as_of]:[]),
      ...(c.status!=="unspecified"?["Knowledge status: "+statusLabels[c.status]]:[]),
      ...(c.aliases.length?["Also known as: "+c.aliases.map(line).join(", ")]:[]),
      ...(c.topics.length?["Topics: "+c.topics.map(line).join(", ")]:[]),
      "",...(c.summary?[c.summary,""]:[]),r.text].join("\n");
  };
  const a=contextOf(existing.context),b=contextOf(incoming.context);
  // Keep each perspective in its own section; combined metadata does not declare one source the winner.
  return {text:section(existing)+"\n\n"+section(incoming),context:{
    ...emptyContext(),type_label:entryType(existing)===entryType(incoming)?entryType(existing):"Mixed material",
    framing:a.framing===b.framing?a.framing:"mixed",
    attribution:a.attribution===b.attribution?a.attribution:"Multiple perspectives; see the attributed sections.",
  } satisfies KnowledgeContext};
}
