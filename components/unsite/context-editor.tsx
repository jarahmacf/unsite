"use client";
import {Plus,Trash2} from "@/components/unsite/icons";
import {Input} from "@/components/ui/input";
import {Textarea} from "@/components/ui/textarea";
import {RELATIONS,KNOWLEDGE_STATES,FRAMINGS,relationLabels,statusLabels,framingLabels,type KnowledgeContext,type KnowledgeLink} from "@/lib/production/knowledge";
import {Choice,Field} from "./shared";
export function ContextEditor({value,onChange,aliases,setAliases,topics,setTopics}:{value:KnowledgeContext;onChange:(c:KnowledgeContext)=>void;aliases:string;setAliases:(v:string)=>void;topics:string;setTopics:(v:string)=>void}){
  return <section className="us-context-editor">
    <h3>Context for agents</h3>
    <Field label="Content type" hint="Use a label that fits this material. Different types can live together.">{id=><Input id={id} maxLength={100} value={value.type_label||""} onChange={e=>onChange({...value,type_label:e.target.value})} placeholder="Essay, recipe, specification, fictional scene…"/>}</Field>
    <div className="us-form-grid">
      <Field label="How to read this">{()=> <Choice label="How to read this entry" value={value.framing||"unspecified"} onChange={framing=>onChange({...value,framing:framing as KnowledgeContext["framing"]})} items={FRAMINGS.map(v=>({value:v,label:framingLabels[v]}))}/>}</Field>
      <Field label="Whose perspective?" hint="Author, speaker, organization, narrator, or character. Leave blank if unknown.">{id=><Input id={id} maxLength={600} value={value.attribution||""} onChange={e=>onChange({...value,attribution:e.target.value})} placeholder="Who is speaking or making this claim?"/>}</Field>
    </div>
    <Field label="Short summary" hint="Explain what this entry covers. Keep the complete explanation in Content.">{id=><Textarea id={id} rows={3} maxLength={1200} value={value.summary} onChange={e=>onChange({...value,summary:e.target.value})}/>}</Field>
    <div className="us-form-grid">
      <Field label="Topics" hint="Separate labels with commas.">{id=><Input id={id} value={topics} onChange={e=>setTopics(e.target.value)} placeholder="Memory, materials, fermentation…"/>}</Field>
      <Field label="Also known as" hint="Names or abbreviations that refer to the same subject.">{id=><Input id={id} value={aliases} onChange={e=>setAliases(e.target.value)} placeholder="Other names for this subject"/>}</Field>
      <Field label="Knowledge status">{()=> <Choice label="Knowledge status" value={value.status} onChange={status=>onChange({...value,status:status as KnowledgeContext["status"]})} items={KNOWLEDGE_STATES.map(v=>({value:v,label:statusLabels[v]}))}/>}</Field>
      <Field label="Applies as of" hint="Use an explicit source date when relevant. Leave blank if unknown or not applicable.">{id=><Input id={id} type="date" value={value.as_of||""} onChange={e=>onChange({...value,as_of:e.target.value||null})}/>}</Field>
    </div>
  </section>;
}
export function LinksEditor({value,onChange,entries,selfId}:{value:KnowledgeLink[];onChange:(v:KnowledgeLink[])=>void;entries:{id:string;title:string}[];selfId?:string}){
  return <section className="us-context-editor"><div className="us-fields-heading"><strong>Relationships</strong><button type="button" disabled={value.length>=30||!entries.some(r=>r.id!==selfId)} onClick={()=>onChange([...value,{relation:"related_to",target_id:""}])}><Plus size={14}/>Add relationship</button></div><p className="us-small us-muted">Connect this entry to approved knowledge so agents can follow its context.</p>{value.map((link,i)=><div className="us-link-editor" key={i}><Choice label={`Relationship ${i+1}`} value={link.relation} onChange={relation=>onChange(value.map((v,j)=>i===j?{...v,relation:relation as KnowledgeLink["relation"]}:v))} items={RELATIONS.map(r=>({value:r,label:relationLabels[r]}))}/><Choice label={`Related entry ${i+1}`} value={link.target_id||"choose"} onChange={target_id=>onChange(value.map((v,j)=>i===j?{...v,target_id:target_id==="choose"?"":target_id}:v))} items={[{value:"choose",label:"Choose an entry"},...entries.filter(r=>r.id!==selfId).map(r=>({value:r.id,label:r.title}))]}/><button type="button" className="us-icon-button" aria-label={`Remove relationship ${i+1}`} onClick={()=>onChange(value.filter((_,j)=>i!==j))}><Trash2 size={16}/></button></div>)}</section>;
}

export function ReadingContext({value}:{value?:KnowledgeContext}){
  const framing=value?.framing||"unspecified",attribution=value?.attribution;
  if(framing==="unspecified"&&!attribution)return null;
  return <p className="us-small us-muted">{framing!=="unspecified"&&<strong>{framingLabels[framing]}</strong>}{attribution&&<span>{framing!=="unspecified"?" · ":""}Perspective: {attribution}</span>}</p>;
}
