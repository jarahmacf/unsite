"use client";
import {useRef,useState} from "react";
import {Sparkles} from "@/components/unsite/icons";
import {AI_DISCLOSURE,AI_DISCLOSURE_VERSION,AI_STOP_DISCLOSURE} from "@/lib/production/ai-consent";
import type {SourceVersion} from "@/lib/production/types";
import {Action,Busy,ErrorNotice,Modal,Pill,type Command} from "./shared";
export function AiPreparationDialog({version,title,mode,command,onClose}:{version:SourceVersion;title:string;mode:"prepare"|"stop";command:Command;onClose:()=>void}){
  const [approved,setApproved]=useState(false),[busy,setBusy]=useState(false),[error,setError]=useState("");
  const request=useRef(crypto.randomUUID());
  async function submit(){setBusy(true);setError("");try{
    await command(mode==="stop"?"stop_preparation":"prepare_source",{version_id:version.id,...(mode==="prepare"?{approved,disclosure_version:AI_DISCLOSURE_VERSION,request_id:request.current}:{})});onClose();
  }catch(e){setError((e as Error).message);}finally{setBusy(false);}}
  return <Modal open onClose={()=>!busy&&onClose()} title={mode==="stop"?"Stop AI preparation?":"Prepare this source with AI"} description={mode==="stop"?AI_STOP_DISCLOSURE:"Review what will be shared before starting preparation."}>
    <div className="us-ai-source"><strong>{title}</strong><Pill>Version {version.version}</Pill></div>
    {mode==="prepare"&&<><p>{AI_DISCLOSURE}</p><label className="us-check"><input type="checkbox" checked={approved} onChange={e=>setApproved(e.target.checked)} disabled={busy}/><span>I approve sending this source version’s extracted text to OpenAI for preparation.</span></label><p className="us-small us-muted">This approval applies to this version only. Retrying an interrupted preparation can repeat a provider request. You can stop further processing from the source history.</p></>}
    <ErrorNotice message={error}/><div className="us-modal-actions"><Action secondary disabled={busy} onClick={onClose}>Cancel</Action><Action disabled={busy||(mode==="prepare"&&!approved)} onClick={submit}>{busy?<Busy label="Saving…"/>:mode==="stop"?"Stop further processing":<><Sparkles size={16}/>Approve & prepare</>}</Action></div>
  </Modal>;
}
