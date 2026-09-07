"use client";
import {useRef,useState,type FormEvent} from "react";
import {ArrowRight} from "@/components/unsite/icons";
import {Input} from "@/components/ui/input";
import {Action,useApi,Busy,ErrorNotice,Field} from "./shared";
import type {Space} from "@/lib/production/types";
export function CreateSpace({onCreated,onCancel}:{onCreated:(s:Space)=>void;onCancel?:()=>void}){
  const api=useApi();
  const [name,setName]=useState(""),[busy,setBusy]=useState(false),[error,setError]=useState(""),request=useRef(crypto.randomUUID());
  async function submit(e:FormEvent){e.preventDefault();setBusy(true);setError("");try{const r=await api<{result:Space}>("/api/app/create_space",{name,request_id:request.current});onCreated(r.result);}catch(e){setError((e as Error).message);}finally{setBusy(false);}}
  return <form className="us-create" onSubmit={submit}><h3>Start with your material</h3><p>Give this collection a name. Add documents, pages, or notes next; you can organize different kinds of material together.</p><Field label="Workspace name">{id=><Input id={id} autoFocus required maxLength={200} value={name} placeholder="Collected work, company knowledge, project archive…" onChange={e=>setName(e.target.value)}/>}</Field><ErrorNotice message={error}/><div className="us-modal-actions">{onCancel?<Action secondary disabled={busy} onClick={onCancel}>Cancel</Action>:<span/>}<Action type="submit" disabled={busy}>{busy?<Busy label="Creating…"/>:<>Create workspace<ArrowRight size={16}/></>}</Action></div></form>;
}
export {Settings} from "./settings";
