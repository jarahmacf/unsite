"use client";
import {useRef,useState} from "react";
import {Sparkles} from "@/components/unsite/icons";
import {AI_STOP_DISCLOSURE} from "@/lib/production/ai-consent";
import {COLLECTION_DISCLOSURE_VERSION} from "@/lib/production/collection";
import {Input} from "@/components/ui/input";
import type {SourceVersion} from "@/lib/production/types";
import {Action,Busy,ErrorNotice,Field,Modal,Pill,type Command} from "./shared";
export function AiPreparationDialog({version,title,mode,command,onClose}:{version:SourceVersion;title:string;mode:"prepare"|"stop";command:Command;onClose:()=>void}){
  const [approved,setApproved]=useState(false),[busy,setBusy]=useState(false),[error,setError]=useState("");
  const request=useRef(crypto.randomUUID());
  const [budget,setBudget]=useState(40);
  async function submit(){setBusy(true);setError("");try{
    await command(mode==="stop"?"stop_preparation":"start_collection_run",mode==="stop"?{version_id:version.id}:{version_ids:[version.id],goal:"Prepare this source and identify changes to existing knowledge. Preserve complete explanations, attribution, qualifications, and conflicting evidence.",max_requests:budget,approved,disclosure_version:COLLECTION_DISCLOSURE_VERSION,request_id:request.current});onClose();
  }catch(e){setError((e as Error).message);}finally{setBusy(false);}}
  return <Modal open onClose={()=>!busy&&onClose()} title={mode==="stop"?"Stop AI preparation?":"Prepare this source with AI"} description={mode==="stop"?AI_STOP_DISCLOSURE:"Review what will be shared before starting preparation."}>
    <div className="us-ai-source"><strong>{title}</strong><Pill>Version {version.version}</Pill></div>
    {mode==="prepare"&&<><p>This source will use the same reading, curation, and evidence-verification stages as a collection. Relevant approved entries provide context for suggested updates.</p><Field label="Maximum AI requests" hint="Includes reading, curation, verification, and retries. This is a request limit, not a dollar limit.">{id=><Input id={id} type="number" min={1} max={200} required disabled={busy} value={budget} onChange={e=>{setBudget(Number(e.target.value));request.current=crypto.randomUUID();}}/>}</Field><label className="us-check"><input type="checkbox" checked={approved} onChange={e=>setApproved(e.target.checked)} disabled={busy}/><span>I approve sending this source version, resulting suggestions, the preparation goal, and relevant existing approved knowledge to OpenAI for extraction, curation, and verification. This may include private information. Results stay private for review.</span></label><p className="us-small us-muted">Track or stop this run under Prepare sources with AI. Stopping prevents future requests; an already-sent request may finish. Nothing publishes automatically.</p></>}
    <ErrorNotice message={error}/><div className="us-modal-actions"><Action secondary disabled={busy} onClick={onClose}>Cancel</Action><Action disabled={busy||(mode==="prepare"&&(!approved||!Number.isInteger(budget)||budget<1||budget>200))} onClick={submit}>{busy?<Busy label="Saving…"/>:mode==="stop"?"Stop further processing":<><Sparkles size={16}/>Approve & prepare</>}</Action></div>
  </Modal>;
}
