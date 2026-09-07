"use client";
import {Action} from "@/components/unsite/shared";
import {RefreshCw} from "@/components/unsite/icons";
export default function WorkspaceError({reset}:{error:Error&{digest?:string};reset:()=>void}){
  return <div className="unsite-console us-centered"><section className="us-card us-route-error"><span className="us-symbol">u</span><h1>Let’s try that again.</h1><p>This page couldn’t finish loading. Your saved work is still in your workspace.</p><Action onClick={reset}><RefreshCw size={17}/>Reload this page</Action></section></div>;
}
