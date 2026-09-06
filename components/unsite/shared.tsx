"use client";
import {Children,cloneElement,createContext,isValidElement,useContext,useId,useRef,type ReactNode} from "react";
import {Loader2,ArrowUpRight} from "lucide-react";
import {Button} from "@/components/ui/button";
import {Select,SelectContent,SelectItem,SelectTrigger,SelectValue} from "@/components/ui/select";
import {Dialog,DialogContent,DialogHeader,DialogTitle,DialogDescription} from "@/components/ui/dialog";
export async function api<T=Record<string,unknown>>(path:string,body?:unknown):Promise<T>{
  const r=await fetch(path,{method:body===undefined?"GET":"POST",credentials:"same-origin",cache:"no-store",headers:body===undefined?{}:{"Content-Type":"application/json"},...(body===undefined?{}:{body:JSON.stringify(body)})});
  let data;try{data=await r.json();}catch{throw new Error("The connection was interrupted. Please try again.");}
  if(!r.ok)throw new Error(data.error||"The request could not be completed.");return data;
}
export type Command=(action:string,payload:Record<string,unknown>)=>Promise<Record<string,unknown>>;
const ApiContext=createContext<typeof api>(api);
export function ApiProvider({request,children}:{request:typeof api;children:ReactNode}){return <ApiContext.Provider value={request}>{children}</ApiContext.Provider>;}
export function useApi(){return useContext(ApiContext);}
export function Choice({value,onChange,items,label,disabled}:{value:string;onChange:(s:string)=>void;items:{value:string;label:string}[];label:string;disabled?:boolean}){
  return <Select value={value} onValueChange={onChange} disabled={disabled}><SelectTrigger className="us-select" aria-label={label}><SelectValue/></SelectTrigger><SelectContent>{items.map(i=><SelectItem key={i.value} value={i.value}>{i.label}</SelectItem>)}</SelectContent></Select>;
}
export function Field({label,hint,children}:{label:string;hint?:string;children:(id:string)=>ReactNode}){
  const id=useId(),hintId=id+"-hint";
  const control=Children.map(children(id),child=>isValidElement<{"aria-describedby"?:string}>(child)&&hint?cloneElement(child,{"aria-describedby":[child.props["aria-describedby"],hintId].filter(Boolean).join(" ")}):child);
  return <div className="us-field"><label htmlFor={id}>{label}</label>{control}{hint&&<small id={hintId}>{hint}</small>}</div>;
}
export function ErrorNotice({message}:{message:string}){return message?<div className="us-error" role="alert">{message}</div>:null;}
export function Busy({label="Loading…"}:{label?:string}){return <span className="us-busy" role="status"><Loader2 size={17} className="us-spin"/>{label}</span>;}
export function Pill({children,tone="neutral"}:{children:ReactNode;tone?:"neutral"|"green"|"amber"|"red"}){return <span className={"us-pill us-pill-"+tone}>{children}</span>;}
export function Empty({icon,title,description,action}:{icon:ReactNode;title:string;description:string;action?:ReactNode}){return <div className="us-empty"><div className="us-empty-icon">{icon}</div><h3>{title}</h3><p>{description}</p>{action}</div>;}
export function Modal({open,onClose,title,description,children,wide=false}:{open:boolean;onClose:()=>void;title:string;description:string;children:ReactNode;wide?:boolean}){
  const restoreFocus=useRef<HTMLElement|null>(null);
  return <Dialog open={open} onOpenChange={v=>!v&&onClose()}><DialogContent className={"us-dialog "+(wide?"us-dialog-wide":"")} onOpenAutoFocus={()=>{restoreFocus.current=document.activeElement instanceof HTMLElement?document.activeElement:null;}} onCloseAutoFocus={event=>{event.preventDefault();if(restoreFocus.current?.isConnected)restoreFocus.current.focus();else document.getElementById("workspace-content")?.focus();}}><DialogHeader><DialogTitle>{title}</DialogTitle><DialogDescription>{description}</DialogDescription></DialogHeader>{children}</DialogContent></Dialog>;
}
export function External({href,children}:{href:string;children:ReactNode}){return <a className="us-link" href={href} target="_blank" rel="noreferrer">{children}<ArrowUpRight size={15}/></a>;}
export function Action({children,onClick,disabled=false,secondary=false,type="button"}:{children:ReactNode;onClick?:()=>void;disabled?:boolean;secondary?:boolean;type?:"button"|"submit"}){return <Button type={type} className={secondary?"us-button-secondary":"us-button"} variant={secondary?"outline":"default"} onClick={onClick} disabled={disabled}>{children}</Button>;}
export function stamp(value:string){return new Date(value).toLocaleString(undefined,{month:"short",day:"numeric",hour:"numeric",minute:"2-digit"});}
export function bytes(n:number){return n<1024?n+" B":n<1048576?(n/1024).toFixed(0)+" KB":(n/1048576).toFixed(1)+" MB";}
export function saveFile(name:string,data:unknown,type="application/json"){const blob=new Blob([typeof data==="string"?data:JSON.stringify(data,null,2)],{type}),url=URL.createObjectURL(blob),a=document.createElement("a");a.href=url;a.download=name;a.click();setTimeout(()=>URL.revokeObjectURL(url),1000);}
