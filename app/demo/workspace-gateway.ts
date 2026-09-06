import type { Candidate, KnowledgeFields, KnowledgeRecord, Release, SpaceState } from "@/lib/production/types";
import { contextOf, type KnowledgeContext, type KnowledgeLink } from "@/lib/production/knowledge";
import { inspectKnowledge, runRetrievalCases, type RetrievalCase } from "@/lib/production/retrieval";
import type { Snapshot } from "@/lib/production/release";
import type { SourceGateway } from "@/components/unsite/source-gateway";
import { sampleGateway, sampleState } from "./fixtures";

export function demoSnapshot(state: SpaceState, links = new Map<string, KnowledgeLink[]>()): Snapshot {
  return { schema_version: "2.1", id: state.space.id, name: state.space.name, kind: state.space.kind, description: state.space.description, contact_email: state.space.contact_email,
    records: state.records.filter(record => record.active).map(record => ({ id: record.id, title: record.title, kind: record.kind, text: record.text, fields: record.fields, context: record.context, source_url: record.public_source_url, revision: record.revision, updated_at: record.updated_at, links: links.get(record.id) || [] })) };
}

// This adapter contains only local sample operations. It has no live API fallback,
// provider credentials, uploads, or database client, even for publication actions.
export function workspaceGateway(getState: () => SpaceState, update: (next: SpaceState) => void): SourceGateway {
  const sources = sampleGateway(getState, update);
  const links = new Map<string, KnowledgeLink[]>();
  const releases = new Map<string, Release>();
  const requests = new Map<string, unknown>();
  let cases: RetrievalCase[] = [{ id: "sample-case", question: "What design services does the studio offer?", expected_record_id: "sample-record-1", expectation: "find" }];

  return { sample: true, upload: sources.upload, async request<T>(path: string, body?: unknown): Promise<T> {
    const state = getState();
    const payload = (body || {}) as Record<string, unknown>;
    const url = new URL(path, "https://demo.invalid");
    const route = url.pathname;
    const requestKey = payload.request_id ? route + ":" + payload.request_id : null;
    if (requestKey && requests.has(requestKey)) return requests.get(requestKey) as T;
    let result: unknown;

    function save(next: SpaceState, action: string, contentChanged = true) {
      update({ ...next, recordCount: next.records.length, candidateCount: next.candidates.length,
        space: { ...next.space, content_revision: state.space.content_revision + (contentChanged ? 1 : 0) },
        activity: [{ id: crypto.randomUUID(), space_id: state.space.id, actor_id: "sample-owner", action, details: {}, created_at: new Date().toISOString() }, ...next.activity] });
    }
    function makeRecord(id: string, previous?: KnowledgeRecord, candidate?: Candidate): KnowledgeRecord {
      return { id, space_id: state.space.id, candidate_id: candidate?.id || previous?.candidate_id || null,
        title: String(payload.title || previous?.title || "Untitled entry"), text: String(payload.text || previous?.text || ""), kind: (payload.kind || previous?.kind || "general") as KnowledgeRecord["kind"],
        fields: (payload.fields || previous?.fields || {}) as KnowledgeFields, context: contextOf((payload.context || previous?.context) as KnowledgeContext | undefined),
        public_source_url: payload.public_source_url === undefined ? previous?.public_source_url || null : String(payload.public_source_url || "") || null,
        revision: (previous?.revision || 0) + 1, active: payload.active === undefined ? previous?.active ?? true : Boolean(payload.active), updated_at: new Date().toISOString() };
    }

    if (route === "/api/app/knowledge") {
      result = { snapshot: demoSnapshot(state, links), source_revision: state.space.content_revision, cases };
    } else if (route === "/api/app/record") {
      const record = state.records.find(item => item.id === url.searchParams.get("id"));
      if (!record) throw new Error("That sample entry no longer exists.");
      result = { record, links: links.get(record.id) || [], history: [], evidence: [] };
    } else if (route === "/api/app/comparisons") {
      result = { matches: [] };
    } else if (route === "/api/app/collection-runs") {
      result = { runs: [], configured: false };
    } else if (route === "/api/app/create_record" || route === "/api/app/edit_record") {
      const previous = state.records.find(record => record.id === payload.record_id);
      if (route.endsWith("edit_record") && (!previous || previous.revision !== payload.revision)) throw new Error("This entry changed. Close the editor and reopen the latest version.");
      const record = makeRecord(previous?.id || crypto.randomUUID(), previous);
      links.set(record.id, (payload.links || links.get(record.id) || []) as KnowledgeLink[]);
      save({ ...state, records: previous ? state.records.map(item => item.id === record.id ? record : item) : [record, ...state.records] }, previous ? "edit_record" : "create_record");
      result = { result: record };
    } else if (route === "/api/app/review_candidate") {
      const candidate = state.candidates.find(item => item.id === payload.candidate_id);
      if (!candidate || candidate.revision !== payload.revision) throw new Error("This sample suggestion has already changed or been reviewed.");
      let records = state.records;
      if (payload.decision === "accept") {
        const previous = records.find(record => record.id === payload.record_id);
        if (payload.record_id && (!previous || previous.revision !== payload.record_revision)) throw new Error("The existing entry changed. Reopen the review to compare its latest version.");
        const record = makeRecord(previous?.id || crypto.randomUUID(), previous, candidate);
        links.set(record.id, (payload.links || []) as KnowledgeLink[]);
        records = previous ? records.map(item => item.id === record.id ? record : item) : [record, ...records];
      }
      save({ ...state, records, candidates: state.candidates.filter(item => item.id !== candidate.id) }, "review_candidate");
      result = { result: {} };
    } else if (route === "/api/app/update_space") {
      if (payload.revision !== state.space.content_revision) throw new Error("Workspace details changed. Reload the saved details and try again.");
      save({ ...state, space: { ...state.space, name: String(payload.name), description: String(payload.description), contact_email: String(payload.contact_email || "") } }, "update_space");
      result = { result: { content_revision: getState().space.content_revision } };
    } else if (route === "/api/app/create_space") {
      const next = sampleState(true); next.space.name = String(payload.name); update(next);
      links.clear(); releases.clear(); requests.clear(); cases = [];
      result = { result: next.space };
    } else if (route === "/api/app/publish_release") {
      if (!payload.reviewed || payload.revision !== state.space.content_revision) throw new Error("Review the latest sample content before simulating a release.");
      const release: Release = { id: crypto.randomUUID(), space_id: state.space.id, revision: state.releases.length + 1, source_revision: state.space.content_revision, published_at: new Date().toISOString(), created_by: "sample-owner", summary: String(payload.summary || "Sample release"), data: structuredClone(demoSnapshot(state, links)) };
      releases.set(release.id, release);
      const { data: _data, ...metadata } = release;
      save({ ...state, releases: [metadata, ...state.releases], space: { ...state.space, active_release_id: release.id } }, "publish_release", false);
      result = { result: metadata };
    } else if (route === "/api/app/release") {
      const release = releases.get(url.searchParams.get("id") || "");
      if (!release) throw new Error("Sample release not found.");
      result = { release: structuredClone(release) };
    } else if (route === "/api/app/rollback_release" || route === "/api/app/unpublish") {
      if (!payload.reviewed) throw new Error("Confirm this sample change first.");
      if (route.endsWith("rollback_release") && !releases.has(String(payload.release_id))) throw new Error("Sample release not found.");
      save({ ...state, space: { ...state.space, active_release_id: route.endsWith("unpublish") ? null : String(payload.release_id) } }, route.split("/").pop()!, false);
      result = { result: {} };
    } else if (route === "/api/app/releases") {
      result = { items: state.releases.slice(Number(url.searchParams.get("offset") || 0)) };
    } else if (route === "/api/app/agent-check") {
      const published = url.searchParams.get("mode") === "published";
      const release = state.space.active_release_id ? releases.get(state.space.active_release_id) : undefined;
      const snapshot = published && release ? release.data as Snapshot : demoSnapshot(state, links);
      result = { mode: published ? "published" : "draft", source_revision: release && published ? release.source_revision : state.space.content_revision, inspection: inspectKnowledge(snapshot), cases: runRetrievalCases(snapshot, cases), transport: null };
    } else if (route === "/api/app/save_retrieval_case") {
      const item: RetrievalCase = { id: crypto.randomUUID(), question: String(payload.question), expectation: payload.expectation as RetrievalCase["expectation"], expected_record_id: payload.expected_record_id ? String(payload.expected_record_id) : null };
      cases = [...cases, item]; result = { result: item };
    } else if (route === "/api/app/delete_retrieval_case") {
      cases = cases.filter(item => item.id !== payload.case_id); result = { result: {} };
    } else {
      // SourceGateway rejects unsupported paths instead of calling fetch.
      return sources.request<T>(path, body);
    }
    if (requestKey) requests.set(requestKey, result);
    return result as T;
  } };
}
