"use client";
import {useCallback,useEffect,useRef,useState} from "react";
import {useWorkspaceTab} from "@/components/unsite/workspace-navigation";
import {AcceptInvitation} from "@/components/unsite/invitation";
import {invitationFromUrl} from "@/lib/production/invitations";
import {Auth} from "@/components/unsite/auth";
import {AddSource,Sources,SourcesSkeleton} from "@/components/unsite/sources";
import {WorkspaceShell} from "@/components/unsite/workspace-shell";
import {Overview} from "@/components/unsite/overview";
import {CreateSpace,Settings} from "@/components/unsite/workspace-forms";
import {Knowledge,Review} from "@/components/unsite/knowledge";
import {AgentLab} from "@/components/unsite/agent-lab";
import {Presence} from "@/components/unsite/presence";
import {Action,api,Busy,ErrorNotice,Modal,type Command} from "@/components/unsite/shared";
import type {RuntimeStatus,Space,SpaceState} from "@/lib/production/types";
type User={id:string;email:string};
export default function WorkspaceApp(){
  const [user,setUser]=useState<User|null|undefined>(),[spaces,setSpaces]=useState<Space[]>([]),[spaceId,setSpaceId]=useState(""),[state,setState]=useState<SpaceState|null>(null),[status,setStatus]=useState<RuntimeStatus|null>(null),[error,setError]=useState(""),[loading,setLoading]=useState(false),[create,setCreate]=useState(false),[adding,setAdding]=useState(false),[authError,setAuthError]=useState("");
  const [tab,setTab]=useWorkspaceTab();
  const [invitation,setInvitation]=useState<ReturnType<typeof invitationFromUrl>>(null);
  const currentId=useRef(""),sequence=useRef(0);
  const loadState=useCallback(async(id:string)=>{if(!id)return;const seq=++sequence.current;try{const s=await api<SpaceState>("/api/app/state?space="+id);if(seq===sequence.current&&currentId.current===id){setState(s);setSpaces(old=>old.map(x=>x.id===id?s.space:x));setError("");}}catch(e){if(seq===sequence.current)setError((e as Error).message);throw e;}},[]);
  const loadAccount=useCallback(async()=>{setLoading(true);setError("");try{const a=await api<{user:User|null}>("/api/auth");setUser(a.user);if(a.user){const result=await api<{spaces:Space[]}>("/api/app/spaces");setSpaces(result.spaces);let saved="";try{saved=localStorage.getItem("unsite.selectedPresence")||"";}catch{}setSpaceId(old=>result.spaces.some(s=>s.id===old)?old:result.spaces.some(s=>s.id===saved)?saved:result.spaces[0]?.id||"");api<RuntimeStatus>("/api/app/status").then(setStatus).catch(()=>setStatus(null));}else{setState(null);setSpaces([]);setSpaceId("");}}catch(e){setError((e as Error).message);setUser(null);}finally{setLoading(false);}},[]);
  useEffect(()=>{setInvitation(invitationFromUrl(new URL(location.href)));if(new URLSearchParams(location.search).has("auth_error"))setAuthError("That confirmation link could not be completed. Request a new link or sign in again.");void loadAccount();},[loadAccount]);
  useEffect(()=>{currentId.current=spaceId;sequence.current++;setState(null);setError("");if(spaceId){try{localStorage.setItem("unsite.selectedPresence",spaceId);}catch{}void loadState(spaceId).catch(()=>{});}},[spaceId,loadState]);
  useEffect(()=>{if(!spaceId||!user)return;const timer=setInterval(()=>{if(document.visibilityState==="visible")void loadState(spaceId).catch(()=>{});},state?.jobs.some(j=>["queued","running"].includes(j.status))?8000:30000);return ()=>clearInterval(timer);},[spaceId,user,loadState,state?.jobs]);
  const reload=useCallback(async()=>{await Promise.all([loadState(currentId.current),api<RuntimeStatus>("/api/app/status").then(setStatus).catch(()=>{})]);},[loadState]);
  const command:Command=async(action,payload)=>{const id=currentId.current;const r=await api<{result:Record<string,unknown>}>("/api/app/"+action,{...payload,space_id:id});try{await loadState(id);}catch{setError("Your change was saved, but the workspace could not refresh. Use Refresh to load the latest state.");}return r.result;};
  async function signOut(){try{await api("/api/auth",{action:"signout"});setState(null);setStatus(null);setSpaces([]);setSpaceId("");setUser(null);currentId.current="";sequence.current++;}catch(e){setError((e as Error).message);}}
  function created(s:Space){setSpaces(v=>v.some(x=>x.id===s.id)?v:[...v,s]);setSpaceId(s.id);setCreate(false);setTab("overview");}
  const role=state?.memberships.find(m=>m.user_id===user?.id)?.role,canEdit=role==="owner"||role==="editor";
  if(user===undefined||loading)return <div className="unsite-console us-centered"><div className="us-loading"><span className="us-symbol">u</span><Busy label="Opening your workspace…"/></div></div>;
  if(!user)return <div className="unsite-console"><Auth key={authError+error} initialError={authError||error} onSignedIn={()=>void loadAccount()}/></div>;
  return <>
    <WorkspaceShell spaces={spaces} spaceId={spaceId} tab={tab} email={user.email} candidateCount={state?.candidateCount} published={!!state?.space.active_release_id}
      onTabChange={setTab} onSpaceChange={id=>{setSpaceId(id);setTab("overview");}} onCreate={()=>setCreate(true)} onSignOut={()=>void signOut()} onRefresh={()=>reload().catch(()=>{})}>
      <ErrorNotice message={error}/>
      {!spaces.length ? <div className="us-onboarding us-card"><span className="us-eyebrow">Start with your material</span><h1>A home for your knowledge.</h1><p>Create your first workspace, then add documents, notes, and the context you want to share.</p><Action onClick={()=>setCreate(true)}>Create a workspace</Action></div>
        : !state ? error ? <div className="us-centered us-state-loading"><Action secondary onClick={()=>void reload().catch(()=>{})}>Try again</Action></div> : <SourcesSkeleton/>
        : <>
          {tab==="overview"&&<Overview canEdit={canEdit} state={state} status={status} setTab={setTab} onAdd={()=>canEdit?setAdding(true):setTab("sources")}/>}
          {tab==="sources"&&<Sources key={state.space.id} state={state} command={command} reload={reload} canEdit={canEdit} aiAvailable={status?.model===true}/>}
          {tab==="knowledge"&&<Knowledge key={state.space.id} state={state} command={command} canEdit={canEdit}/>}
          {tab==="review"&&<Review key={state.space.id} state={state} command={command} canEdit={canEdit}/>}
          {tab==="agents"&&<AgentLab key={state.space.id} state={state} status={status} command={command} canEdit={canEdit}/>}
          {tab==="publish"&&<Presence key={state.space.id} state={state} status={status} command={command} isOwner={role==="owner"}/>}
          {tab==="settings"&&<Settings key={state.space.id} state={state} user={user} status={status} command={command} signOut={()=>void signOut()} canEdit={canEdit} onLeft={loadAccount}/>}
        </>}
    </WorkspaceShell>
    {create&&<Modal open onClose={()=>setCreate(false)} title="Create a workspace" description="Keep separate bodies of knowledge in their own spaces."><CreateSpace onCreated={created} onCancel={()=>setCreate(false)}/></Modal>}
    {invitation&&<AcceptInvitation invitation={invitation} email={user.email} onClose={()=>setInvitation(null)} onAccepted={async id=>{setInvitation(null);const url=new URL(location.href);url.searchParams.delete("invite");url.searchParams.delete("token");history.replaceState(null,"",url);try{localStorage.setItem("unsite.selectedPresence",id);}catch{}await loadAccount();setSpaceId(id);setTab("overview");}}/>}
    {adding&&state&&<AddSource spaceId={state.space.id} open onClose={()=>setAdding(false)} onSaved={reload} aiAvailable={status?.model===true}/>}
  </>;
}
