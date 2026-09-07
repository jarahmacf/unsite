"use client";

import { useRef, useState, useSyncExternalStore } from "react";
import { AddSource, Sources, SourcesSkeleton } from "@/components/unsite/sources";
import { WorkspaceShell } from "@/components/unsite/workspace-shell";
import {useWorkspaceTab} from "@/components/unsite/workspace-navigation";
import { CreateSpace, Settings } from "@/components/unsite/workspace-forms";
import { Overview } from "@/components/unsite/overview";
import { Knowledge, Review } from "@/components/unsite/knowledge";
import { AgentLab } from "@/components/unsite/agent-lab";
import { Presence } from "@/components/unsite/presence";
import { Action, ApiProvider, Busy, ErrorNotice, Modal, type Command } from "@/components/unsite/shared";
import type { RuntimeStatus } from "@/lib/production/types";
import { sampleState } from "./fixtures";
import { workspaceGateway } from "./workspace-gateway";

const status: RuntimeStatus = { storage: false, processing: false, model: false, modelName: null, publicBase: "", domains: false };
const user = { id: "sample-owner", email: "preview@example.com" };
const subscribe = () => () => {};
const clientSnapshot = () => true;
const serverSnapshot = () => false;

function SampleWorkspace({ onReset }: { onReset: () => void }) {
  const [state, setState] = useState(() => sampleState());
  const [tab, setTab] = useWorkspaceTab();
  const [adding, setAdding] = useState(false);
  const [creating, setCreating] = useState(false);
  const [scenario, setScenario] = useState("populated");
  const [sourceGeneration, setSourceGeneration] = useState(0);
  const current = useRef(state);
  const [gateway] = useState(() => workspaceGateway(() => current.current, next => { current.current = next; setState(next); }));
  const reload = async () => { setState({ ...current.current }); };
  const command: Command = async (action, payload) => {
    const response = await gateway.request<{ result: Record<string, unknown> }>("/api/app/" + action, payload);
    return response.result;
  };
  function sourceScenario(value: string) {
    setScenario(value); setSourceGeneration(count => count + 1);
    if (value === "empty" || value === "populated") {
      const sample = sampleState(value === "empty");
      const next = { ...current.current, sources: sample.sources, versions: sample.versions, jobs: sample.jobs };
      current.current = next; setState(next);
    }
  }

  return <ApiProvider request={gateway.request}>
    <WorkspaceShell spaces={[state.space]} spaceId={state.space.id} tab={tab} email={user.email} sample candidateCount={state.candidateCount} published={!!state.space.active_release_id}
      onTabChange={setTab} onSpaceChange={() => setTab("overview")} onCreate={() => setCreating(true)} onSignOut={onReset} onRefresh={reload}>
      <div className="us-sample-notice"><span>Demo workspace · sample content · changes reset on reload</span><button type="button" onClick={onReset}>Reset demo</button></div>
      {tab === "overview" && <Overview state={state} status={status} setTab={setTab} onAdd={() => setAdding(true)} />}
      {tab === "sources" && <>
        <details className="us-demo-states"><summary>Explore source states</summary><div className="us-toolbar" aria-label="Preview scenarios">{["populated", "empty", "loading", "error"].map(value => <button type="button" className="us-button-secondary" aria-pressed={scenario === value} key={value} onClick={() => sourceScenario(value)}>{value.charAt(0).toUpperCase() + value.slice(1)}</button>)}</div></details>
        {scenario === "loading" ? <SourcesSkeleton /> : scenario === "error" ? <><ErrorNotice message="Your sources couldn’t load. Try again to reconnect to the workspace." /><Action secondary onClick={() => sourceScenario("populated")}>Try again</Action></> : <Sources key={state.space.id + ":" + sourceGeneration} state={state} canEdit aiAvailable={false} gateway={gateway} reload={reload} command={command} />}
      </>}
      {tab === "knowledge" && <Knowledge state={state} canEdit command={command} />}
      {tab === "review" && <Review state={state} canEdit command={command} />}
      {tab === "agents" && <AgentLab state={state} status={status} canEdit command={command} sample />}
      {tab === "publish" && <Presence state={state} status={status} isOwner command={command} sample />}
      {tab === "settings" && <Settings sample state={state} status={status} user={user} canEdit command={command} signOut={onReset} />}
    </WorkspaceShell>
    {adding && <AddSource spaceId={state.space.id} open onClose={() => setAdding(false)} onSaved={reload} aiAvailable={false} gateway={gateway} />}
    {creating && <Modal open onClose={() => setCreating(false)} title="Create a sample workspace" description="Try an empty workspace. Reset the demo to return to the original sample."><CreateSpace onCreated={() => { setCreating(false); setTab("overview"); }} onCancel={() => setCreating(false)} /></Modal>}
  </ApiProvider>;
}

export function DemoWorkspace() {
  const [generation, setGeneration] = useState(0);
  const hydrated = useSyncExternalStore(subscribe, clientSnapshot, serverSnapshot);
  // Match server/client markup before locale-sensitive dates and UI state render.
  if (!hydrated) return <div className="unsite-console us-centered"><Busy label="Opening the sample workspace…" /></div>;
  return <SampleWorkspace key={generation} onReset={() => setGeneration(value => value + 1)} />;
}
