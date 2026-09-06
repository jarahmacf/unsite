"use client";

import { useRef, useState, type ReactNode } from "react";
import {
  BookOpen, CheckCheck, ChevronRight, FileText, FlaskConical, Globe,
  LayoutDashboard, LogOut, Menu, Plus, RefreshCw, Settings2, ShieldCheck,
} from "lucide-react";
import { Sheet, SheetContent, SheetHeader, SheetTitle, SheetDescription } from "@/components/ui/sheet";
import { Choice, Pill } from "./shared";
import type { Space } from "@/lib/production/types";

export type WorkspaceTab = "overview" | "sources" | "knowledge" | "review" | "agents" | "publish" | "settings";
export const workspaceNavigation = [
  { id: "overview", label: "Overview", icon: LayoutDashboard },
  { id: "sources", label: "Sources", icon: FileText },
  { id: "knowledge", label: "Knowledge", icon: BookOpen },
  { id: "review", label: "Review", icon: CheckCheck },
  { id: "agents", label: "Agent access", icon: FlaskConical },
  { id: "publish", label: "Publish", icon: Globe },
] as const;

type ShellProps = {
  children: ReactNode;
  spaces: Space[];
  spaceId: string;
  tab: WorkspaceTab;
  email: string;
  candidateCount?: number;
  published?: boolean;
  sample?: boolean;
  enabledTabs?: WorkspaceTab[];
  onTabChange: (tab: WorkspaceTab) => void;
  onSpaceChange: (id: string) => void;
  onCreate: () => void;
  onSignOut: () => void;
  onRefresh: () => Promise<void>;
};

export function Brand() {
  return <a href="/" className="us-brand" aria-label="Unsite home"><span className="us-symbol" aria-hidden="true">u</span>unsite<span className="us-word-dot">.</span></a>;
}

function Navigation({ spaces, spaceId, tab, email, candidateCount = 0, onTabChange, onSpaceChange, onCreate, onSignOut, sample, enabledTabs }: Omit<ShellProps, "children" | "onRefresh">) {
  return <>
    <Brand />
    <div className="us-space-switcher">
      <span className="us-sidebar-label">Workspace</span>
      {spaces.length ? <Choice label="Switch workspace" value={spaceId || spaces[0].id} onChange={onSpaceChange} items={spaces.map(s => ({ value: s.id, label: s.name }))} /> : <span className="us-sidebar-muted">Your first workspace starts here</span>}
      <button type="button" onClick={onCreate}><Plus size={15} />New workspace</button>
    </div>
    <nav aria-label="Main navigation">
      {workspaceNavigation.map(item => <button type="button" key={item.id} disabled={!spaceId || !!enabledTabs && !enabledTabs.includes(item.id)} className={tab === item.id ? "active" : ""} onClick={() => onTabChange(item.id)} aria-current={tab === item.id ? "page" : undefined}>
        <item.icon size={19} /><span>{item.label}</span>{item.id === "review" && candidateCount > 0 && <em>{candidateCount}</em>}
      </button>)}
    </nav>
    <div className="us-sidebar-bottom">
      <div className="us-private-note"><ShieldCheck size={18} /><span>Private by default<small>You choose what goes live.</small></span></div>
      <button type="button" className={"us-settings-button " + (tab === "settings" ? "active" : "")} aria-current={tab === "settings" ? "page" : undefined} onClick={() => onTabChange("settings")} disabled={!spaceId || !!enabledTabs && !enabledTabs.includes("settings")}><Settings2 size={19} />Settings</button>
      <div className="us-account">
        <span className="us-avatar" aria-hidden="true">{email.slice(0, 1).toUpperCase()}</span>
        <span><strong>{sample ? "Sample account" : "Your account"}</strong><small title={email}>{email}</small></span>
        <button type="button" aria-label={sample ? "Reset sample workspace" : "Sign out"} onClick={onSignOut}><LogOut size={17} /></button>
      </div>
    </div>
  </>;
}

export function WorkspaceShell(props: ShellProps) {
  const [mobileOpen, setMobileOpen] = useState(false);
  const [refreshing, setRefreshing] = useState(false);
  const menuButton = useRef<HTMLButtonElement>(null);
  const current = props.spaces.find(space => space.id === props.spaceId);
  const label = workspaceNavigation.find(item => item.id === props.tab)?.label || "Settings";
  function changeTab(tab: WorkspaceTab) { props.onTabChange(tab); setMobileOpen(false); }
  async function refresh() { setRefreshing(true); try { await props.onRefresh(); } finally { setRefreshing(false); } }
  const navigationProps = { ...props, onTabChange: changeTab, onCreate: () => { props.onCreate(); setMobileOpen(false); }, onSpaceChange: (id: string) => { props.onSpaceChange(id); setMobileOpen(false); } };

  return <div className="unsite-console us-shell">
    <a className="us-skip-link" href="#workspace-content">Skip to content</a>
    <aside className="us-sidebar"><Navigation {...navigationProps} /></aside>
    <Sheet open={mobileOpen} onOpenChange={setMobileOpen}>
      <SheetContent side="left" className="us-dialog us-mobile-sidebar" onCloseAutoFocus={event => { event.preventDefault(); menuButton.current?.focus(); }}>
        <SheetHeader className="sr-only"><SheetTitle>Workspace navigation</SheetTitle><SheetDescription>Choose a workspace or a section of Unsite.</SheetDescription></SheetHeader>
        <Navigation {...navigationProps} />
      </SheetContent>
    </Sheet>
    <div className="us-main">
      <header className="us-topbar">
        <div className="us-breadcrumbs"><button ref={menuButton} type="button" className="us-icon-button us-menu-button" aria-label="Open navigation" onClick={() => setMobileOpen(true)}><Menu size={21} /></button><BookOpen size={17} className="us-breadcrumb-icon" /><span>{current?.name || "Your workspace"}</span><ChevronRight size={15} /><strong>{label}</strong></div>
        <div className="us-topbar-actions"><Pill>{props.sample ? "Sample workspace" : props.published ? "Published" : "Private draft"}</Pill><button type="button" className="us-icon-button" aria-label="Refresh workspace" disabled={refreshing} onClick={() => void refresh()}><RefreshCw size={17} className={refreshing ? "us-spin" : ""} /></button></div>
      </header>
      <main id="workspace-content" tabIndex={-1} className="us-main-content">{props.children}</main>
    </div>
  </div>;
}
