"use client";
import {useCallback,useEffect,useState} from "react";
import type {WorkspaceTab} from "./workspace-shell";
const tabs=new Set(["overview","sources","knowledge","review","agents","publish","settings"]);
export function useWorkspaceTab(){
  const [tab,update]=useState<WorkspaceTab>("overview");
  useEffect(()=>{const read=()=>{const value=new URLSearchParams(location.search).get("tab")||"overview";update(tabs.has(value)?value as WorkspaceTab:"overview");};read();window.addEventListener("popstate",read);return()=>window.removeEventListener("popstate",read);},[]);
  const setTab=useCallback((next:WorkspaceTab)=>{update(next);const url=new URL(location.href);if(next==="overview")url.searchParams.delete("tab");else url.searchParams.set("tab",next);if(url.href!==location.href)history.pushState(null,"",url);document.getElementById("workspace-content")?.scrollTo({top:0});},[]);
  return [tab,setTab] as const;
}
