"use client";
import {useState} from "react";
import {Action,Busy,ErrorNotice,Modal,api} from "./shared";
export function AcceptInvitation({invitation,email,onClose,onAccepted}:{invitation:{invitation_id:string;token:string};email:string;onClose:()=>void;onAccepted:(spaceId:string)=>Promise<void>}){
  const [busy,setBusy]=useState(false),[error,setError]=useState("");
  async function accept(){setBusy(true);setError("");try{const response=await api<{result:{space_id:string}}>("/api/app/accept_invitation",invitation);await onAccepted(response.result.space_id);}catch(e){setError((e as Error).message);}finally{setBusy(false);}}
  return <Modal open readOnly onClose={()=>!busy&&onClose()} title="Join a workspace" description="Accept an invitation to collaborate on a private collection."><p>You’re signed in as <strong>{email}</strong>. The invitation must match your confirmed email address.</p><p className="us-muted">Your existing workspaces remain available after you join.</p><ErrorNotice message={error}/><div className="us-modal-actions"><Action secondary disabled={busy} onClick={onClose}>Not now</Action><Action disabled={busy} onClick={()=>void accept()}>{busy?<Busy label="Joining…"/>:"Accept invitation"}</Action></div></Modal>;
}
