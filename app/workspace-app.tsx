"use client";
import {useCallback,useEffect,useRef,useState,type FormEvent} from "react";
import {ArrowRight,LogOut} from "lucide-react";
import {Input} from "@/components/ui/input";
import {Textarea} from "@/components/ui/textarea";
import {Auth} from "@/components/unsite/auth";
import {AddSource,Sources,SourcesSkeleton} from "@/components/unsite/sources";
import {WorkspaceShell,type WorkspaceTab} from "@/components/unsite/workspace-shell";
import {Overview} from "@/components/unsite/overview";
import {Knowledge,Review} from "@/components/unsite/knowledge";
import {AgentLab} from "@/components/unsite/agent-lab";
import {Presence} from "@/components/unsite/presence";
import {Action,api,Busy,ErrorNotice,Field,Modal,Pill,type Command} from "@/components/unsite/shared";
import type {RuntimeStatus,Space,SpaceState} from "@/lib/production/types";
type Tab=WorkspaceTab;
type User={id:string;email:string};
function CreateSpace({onCreated,onCancel}:{onCreated:(s:Space)=>void;onCancel?:()=>void}){
  const [name,setName]=useState(""),[busy,setBusy]=useState(false),[error,setError]=useState(""),request=useRef(crypto.randomUUID());
  async function submit(e:FormEvent){e.preventDefault();setBusy(true);setError("");try{const r=await api<{result:Space}>("/api/app/create_space",{name,request_id:request.current});onCreated(r.result);}catch(e){setError((e as Error).message);}finally{setBusy(false);}}
  return <form className="us-create" onSubmit={submit}><span className="us-eyebrow">Start with your material</span><h1>What are you bringing to Unsite?</h1><p>Give this collection a name. Add documents, pages, or notes next; you can organize different kinds of material together.</p><Field label="Workspace name">{id=><Input id={id} autoFocus required maxLength={200} value={name} placeholder="Collected work, company knowledge, project archive…" onChange={e=>setName(e.target.value)}/>}</Field><ErrorNotice message={error}/><div className="us-modal-actions">{onCancel?<Action secondary disabled={busy} onClick={onCancel}>Cancel</Action>:<span/>}<Action type="submit" disabled={busy}>{busy?<Busy label="Creating…"/>:<>Create workspace<ArrowRight size={16}/></>}</Action></div></form>;
}
function Settings({state,user,status,command,signOut,canEdit}:{state:SpaceState;user:User;status:RuntimeStatus|null;command:Command;signOut:()=>void;canEdit:boolean}){
  const [name,setName]=useState(state.space.name),[description,setDescription]=useState(state.space.description),[email,setEmail]=useState(state.space.contact_email),[revision,setRevision]=useState(state.space.content_revision),[busy,setBusy]=useState(false),[error,setError]=useState(""),[saved,setSaved]=useState(false);
  async function submit(e:FormEvent){e.preventDefault();setBusy(true);setError("");setSaved(false);try{const r=await command("update_space",{name,description,contact_email:email,revision});setRevision(Number(r.content_revision));setSaved(true);}catch(e){setError((e as Error).message);}finally{setBusy(false);}}
  return <><div className="us-section-heading"><div><span className="us-eyebrow">The details that matter</span><h1>Settings</h1><p>Manage this presence and your account.</p></div></div><div className="us-settings-grid"><section className="us-card"><h3>Presence details</h3><p className="us-muted">These details become public when you publish a release.</p><form onSubmit={submit}><fieldset disabled={!canEdit||busy}><Field label="Name">{id=><Input id={id} required maxLength={200} value={name} onChange={e=>setName(e.target.value)}/>}</Field><Field label="Description">{id=><Textarea id={id} rows={5} maxLength={5000} value={description} onChange={e=>setDescription(e.target.value)} placeholder="What does this collection cover, and how should an agent use it?"/>}</Field><Field label="Public contact email (optional)" hint="This is separate from your private account email.">{id=><Input id={id} type="email" value={email} onChange={e=>setEmail(e.target.value)}/>}</Field></fieldset><ErrorNotice message={error}/>{saved&&<p className="us-success" role="status">Details saved to your draft.</p>}<div className="us-modal-actions"><button type="button" className="us-link" onClick={()=>{setName(state.space.name);setDescription(state.space.description);setEmail(state.space.contact_email);setRevision(state.space.content_revision);setError("");}}>Reload saved details</button>{canEdit&&<Action type="submit" disabled={busy}>{busy?<Busy/>:"Save details"}</Action>}</div></form></section><div><section className="us-card"><h3>Your account</h3><p>{user.email}</p><p className="us-small us-muted">Account email is private unless you separately add it as a public contact.</p><button className="us-link" onClick={signOut}><LogOut size={15}/>Sign out</button></section><section className="us-card us-service-state"><h3>Service availability</h3>{[{label:"Private storage",ready:status?.storage},{label:"Background processing",ready:status?.processing},{label:"Automatic preparation",ready:status?.model},{label:"Custom domains",ready:status?.domains}].map(s=><div className="us-between" key={s.label}><span>{s.label}</span><Pill tone={s.ready?"green":"amber"}>{s.ready?"Connected":"Setup pending"}</Pill></div>)}</section></div></div></>;
}
export default function WorkspaceApp(){
  const [user,setUser]=useState<User|null|undefined>(),[spaces,setSpaces]=useState<Space[]>([]),[spaceId,setSpaceId]=useState(""),[state,setState]=useState<SpaceState|null>(null),[status,setStatus]=useState<RuntimeStatus|null>(null),[tab,setTab]=useState<Tab>("overview"),[error,setError]=useState(""),[loading,setLoading]=useState(false),[create,setCreate]=useState(false),[adding,setAdding]=useState(false),[authError,setAuthError]=useState("");
  const currentId=useRef(""),sequence=useRef(0);
  const loadState=useCallback(async(id:string)=>{if(!id)return;const seq=++sequence.current;try{const s=await api<SpaceState>("/api/app/state?space="+id);if(seq===sequence.current&&currentId.current===id){setState(s);setSpaces(old=>old.map(x=>x.id===id?s.space:x));setError("");}}catch(e){if(seq===sequence.current)setError((e as Error).message);throw e;}},[]);
  const loadAccount=useCallback(async()=>{setLoading(true);setError("");try{const a=await api<{user:User|null}>("/api/auth");setUser(a.user);if(a.user){const result=await api<{spaces:Space[]}>("/api/app/spaces");setSpaces(result.spaces);let saved="";try{saved=localStorage.getItem("unsite.selectedPresence")||"";}catch{}setSpaceId(old=>result.spaces.some(s=>s.id===old)?old:result.spaces.some(s=>s.id===saved)?saved:result.spaces[0]?.id||"");api<RuntimeStatus>("/api/app/status").then(setStatus).catch(()=>setStatus(null));}else{setState(null);setSpaces([]);setSpaceId("");}}catch(e){setError((e as Error).message);setUser(null);}finally{setLoading(false);}},[]);
  useEffect(()=>{if(new URLSearchParams(location.search).has("auth_error"))setAuthError("That confirmation link could not be completed. Request a new link or sign in again.");void loadAccount();},[loadAccount]);
  useEffect(()=>{currentId.current=spaceId;sequence.current++;setState(null);setError("");if(spaceId){try{localStorage.setItem("unsite.selectedPresence",spaceId);}catch{}void loadState(spaceId).catch(()=>{});}},[spaceId,loadState]);
  useEffect(()=>{if(!spaceId||!user)return;const timer=setInterval(()=>{if(document.visibilityState==="visible")void loadState(spaceId).catch(()=>{});},state?.jobs.some(j=>["queued","running"].includes(j.status))?8000:30000);return ()=>clearInterval(timer);},[spaceId,user,loadState,state?.jobs]);
  const reload=useCallback(async()=>{await Promise.all([loadState(currentId.current),api<RuntimeStatus>("/api/app/status").then(setStatus).catch(()=>{})]);},[loadState]);
  const command:Command=async(action,payload)=>{const id=currentId.current;const r=await api<{result:Record<string,unknown>}>("/api/app/"+action,{...payload,space_id:id});try{await loadState(id);}catch{setError("Your change was saved, but the workspace could not refresh. Use Refresh to load the latest state.");}return r.result;};
  async function signOut(){try{await api("/api/auth",{action:"signout"});setState(null);setStatus(null);setSpaces([]);setSpaceId("");setUser(null);currentId.current="";sequence.current++;}catch(e){setError((e as Error).message);}}
  async function more(resource:"records"|"candidates"){if(!state)return;const id=spaceId,count=state[resource].length,p=await api<{items:unknown[]}>(`/api/app/${resource}?space=${id}&offset=${count}`);if(currentId.current===id)setState(s=>s?{...s,[resource]:[...s[resource],...p.items]} as SpaceState:s);}
  function created(s:Space){setSpaces(v=>v.some(x=>x.id===s.id)?v:[...v,s]);setSpaceId(s.id);setCreate(false);setTab("overview");}
  const role=state?.memberships.find(m=>m.user_id===user?.id)?.role,canEdit=role==="owner"||role==="editor";
  if(user===undefined||loading)return <div className="unsite-console us-centered"><div className="us-loading"><span className="us-symbol">u</span><Busy label="Opening your workspace…"/></div></div>;
  if(!user)return <div className="unsite-console"><Auth key={authError+error} initialError={authError||error} onSignedIn={()=>void loadAccount()}/></div>;
  return <>
    <WorkspaceShell spaces={spaces} spaceId={spaceId} tab={tab} email={user.email} candidateCount={state?.candidateCount} published={!!state?.space.active_release_id}
      onTabChange={setTab} onSpaceChange={id=>{setSpaceId(id);setTab("overview");}} onCreate={()=>setCreate(true)} onSignOut={()=>void signOut()} onRefresh={()=>reload().catch(()=>{})}>
      <ErrorNotice message={error}/>
      {!spaces.length ? <div className="us-onboarding"><CreateSpace onCreated={created}/></div>
        : !state ? error ? <div className="us-centered us-state-loading"><Action secondary onClick={()=>void reload().catch(()=>{})}>Try again</Action></div> : <SourcesSkeleton/>
        : <>
          {tab==="overview"&&<Overview state={state} status={status} setTab={setTab} onAdd={()=>canEdit?setAdding(true):setTab("sources")}/>}
          {tab==="sources"&&<Sources key={state.space.id} state={state} command={command} reload={reload} canEdit={canEdit} aiAvailable={status?.model===true}/>}
          {tab==="knowledge"&&<Knowledge key={state.space.id} state={state} command={command} loadMore={()=>more("records")} canEdit={canEdit}/>}
          {tab==="review"&&<Review key={state.space.id} state={state} command={command} loadMore={()=>more("candidates")} canEdit={canEdit}/>}
          {tab==="agents"&&<AgentLab key={state.space.id} state={state} status={status} command={command} canEdit={canEdit}/>}
          {tab==="publish"&&<Presence key={state.space.id} state={state} status={status} command={command} isOwner={role==="owner"}/>}
          {tab==="settings"&&<Settings key={state.space.id} state={state} user={user} status={status} command={command} signOut={()=>void signOut()} canEdit={canEdit}/>}
        </>}
    </WorkspaceShell>
    {create&&spaces.length>0&&<Modal open onClose={()=>setCreate(false)} title="Create a workspace" description="Keep separate bodies of knowledge in their own spaces."><CreateSpace onCreated={created} onCancel={()=>setCreate(false)}/></Modal>}
    {adding&&state&&<AddSource spaceId={state.space.id} open onClose={()=>setAdding(false)} onSaved={reload} aiAvailable={status?.model===true}/>}
  </>;
}
