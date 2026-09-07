import type { Candidate, Job, KnowledgeRecord, Source, SourceVersion, SpaceState } from "@/lib/production/types";
import type { SourceGateway } from "@/components/unsite/source-gateway";

import { contextOf } from "@/lib/production/knowledge";

const spaceId = "sample-workspace";
const createdAt = "2026-09-06T10:00:00.000Z";
const sampleSources = [
  { title: "Studio overview.pdf", kind: "file", text: "Fieldwork is an independent design studio.\n\nWe help small teams turn complex products into clear, useful experiences. Our work spans strategy, identity, and digital product design.\n\nThis is synthetic content for the Unsite interface preview." },
  { title: "How we work", kind: "url", text: "Every engagement starts with a question.\n\nWe map the context, explore possible directions, and work closely with the team to shape the result. Projects are scoped together after an introductory conversation." },
  { title: "Notes from the studio", kind: "text", text: "A few things we return to:\n\nClarity is a practice.\nGood questions make room for better answers.\nThe smallest useful version is a good place to begin.\n\nThese are sample notes, stored only in this preview." },
  { title: "Services and capabilities.md", kind: "file", text: "Our capabilities\n\nProduct strategy\nInformation architecture\nInterface design\nVisual identity\n\nWe build a small team around the needs of each project." },
  { title: "Frequently asked questions.txt", kind: "file", text: "Where do we work?\nWe collaborate remotely.\n\nHow does a project begin?\nWith a conversation about the problem, constraints, and desired outcome." },
  { title: "Earlier studio introduction", kind: "text", text: "This archived note demonstrates how source history remains available." },
] satisfies { title: string; kind: Source["kind"]; text: string }[];

export function sampleState(empty = false): SpaceState {
  const sources: Source[] = empty ? [] : sampleSources.map((source, index) => ({ id: "sample-source-" + index, space_id: spaceId, title: source.title, kind: source.kind, origin_url: source.kind === "url" ? "https://example.com/studio" : null, created_at: createdAt, archived_at: index === 5 ? createdAt : null }));
  const versions: SourceVersion[] = sources.map((source, index) => ({ id: "sample-version-" + index, source_id: source.id, space_id: spaceId, version: 1, storage_path: null, mime_type: source.kind === "file" ? "application/pdf" : "text/plain", byte_size: new TextEncoder().encode(sampleSources[index].text).length, text_content: sampleSources[index].text, extracted_text: sampleSources[index].text, content_hash: null, created_at: createdAt }));
  const jobs: Job[] = versions.map((version, index) => ({ id: "sample-job-" + index, space_id: spaceId, source_version_id: version.id, status: index === 1 ? "completed" : index === 3 ? "running" : index === 4 ? "failed" : "blocked", stage: index === 1 ? "complete" : index === 3 ? "read" : "awaiting_approval", attempts: 1, max_attempts: 3, progress: index === 1 ? 100 : index === 3 ? 42 : 0, error_code: index === 4 ? "READ_FAILED" : index === 0 || index === 2 || index === 5 ? "AI_APPROVAL_REQUIRED" : null, error_message: index === 4 ? "This sample shows a reading error. Retry reading to see the recovered state." : null, run_after: createdAt, created_at: createdAt, updated_at: createdAt }));
  const records: KnowledgeRecord[] = empty ? [] : [
    { title: "About Fieldwork", kind: "about", text: sampleSources[0].text, summary: "An independent design studio for teams building thoughtful products.", topics: ["studio", "design"], fields: { structure: "Independent studio" } },
    { title: "Design services", kind: "offering", text: sampleSources[3].text, summary: "Product strategy, information architecture, interface design, and visual identity.", topics: ["services", "product design"], fields: { engagement: "Scoped per project" } },
    { title: "How a project begins", kind: "faq", text: sampleSources[1].text, summary: "Start with a conversation about the problem, the team, and the desired outcome.", topics: ["process", "projects"], fields: {} },
  ].map((record, index) => ({ id: "sample-record-" + index, space_id: spaceId, candidate_id: null, kind: record.kind as KnowledgeRecord["kind"], title: record.title, text: record.text, fields: record.fields as KnowledgeRecord["fields"], context: contextOf({ summary: record.summary, topics: record.topics, framing: "source_claim", attribution: "Fieldwork Studio (sample)", status: "current", as_of: "2026-09-06" }), public_source_url: null, revision: 1, active: true, updated_at: createdAt }));
  const candidates: Candidate[] = empty ? [] : [{
    id: "sample-candidate-0", space_id: spaceId, source_version_id: "sample-version-1", job_id: "sample-job-1",
    kind: "general", title: "A collaborative project process",
    text: "Fieldwork maps the context, explores possible directions, and works with the team to shape the result.",
    fields: {}, context: contextOf({ summary: "A process built around shared context and exploration.", topics: ["collaboration", "process"], framing: "source_claim", attribution: "Fieldwork Studio (sample)" }),
    suggested_links: [], evidence: [{ quote: "We map the context, explore possible directions, and work closely with the team to shape the result.", locator: "How we work · paragraph 2", source_version_id: "sample-version-1" }],
    warnings: [], status: "proposed", revision: 1, created_at: createdAt,
  }];
  return { space: { id: spaceId, owner_id: "sample-owner", name: "Fieldwork Studio", kind: "collection", description: "A sample studio workspace for exploring the Unsite UI.", contact_email: "", active_release_id: null, content_revision: 1, created_at: createdAt }, sources, versions, jobs, candidates, records, releases: [], activity: empty ? [] : [{ id: "sample-activity", space_id: spaceId, action: "create_record", actor_id: "sample-owner", details: {}, created_at: createdAt }], memberships: [{ user_id: "sample-owner", role: "owner" }], candidateCount: candidates.length, recordCount: records.length, aiAuthorizations: [] };
}

export function sampleGateway(getState: () => SpaceState, update: (next: SpaceState) => void): SourceGateway {
  const requestIds = new Map<string, string>();
  return {
    sample: true,
    async request<T>(path: string, body?: unknown): Promise<T> {
      const current = getState();
      const payload = (body || {}) as Record<string, unknown>;
      let result: unknown;
      if (path.startsWith("/api/app/version?id=")) {
        const version = current.versions.find(item => item.id === path.split("=")[1]);
        if (!version) throw new Error("Sample version not found.");
        result = { version, downloadUrl: null };
      } else if (path === "/api/app/source_intake") {
        const previousId = requestIds.get(String(payload.request_id));
        if (previousId) return { result: current.versions.find(item => item.id === previousId), uploadComplete: true } as T;
        const sourceId = String(payload.source_id || crypto.randomUUID());
        const created = new Date().toISOString();
        const source: Source = { id: sourceId, space_id: spaceId, title: String(payload.title), kind: payload.kind as Source["kind"], origin_url: payload.origin_url ? String(payload.origin_url) : null, created_at: created, archived_at: null };
        const version: SourceVersion = { id: crypto.randomUUID(), source_id: sourceId, space_id: spaceId, version: current.versions.filter(item => item.source_id === sourceId).length + 1, storage_path: null, mime_type: String(payload.mime_type || "text/plain"), byte_size: Number(payload.byte_size || 0), text_content: payload.text_content ? String(payload.text_content) : "Sample original. Files and web pages are represented locally in this preview; nothing was uploaded or fetched.", extracted_text: null, content_hash: null, created_at: created };
        requestIds.set(String(payload.request_id), version.id);
        update({ ...current, sources: current.sources.some(item => item.id === sourceId) ? current.sources : [source, ...current.sources], versions: [version, ...current.versions] });
        result = { result: version, uploadComplete: true };
      } else if (path === "/api/app/archive_source") {
        update({ ...current, sources: current.sources.map(source => source.id === payload.source_id ? { ...source, archived_at: new Date().toISOString() } : source) });
        result = { result: {} };
      } else if (path === "/api/app/retry_job" || path === "/api/app/cancel_job") {
        update({ ...current, jobs: current.jobs.map(job => job.id === payload.job_id ? { ...job, status: path.endsWith("retry_job") ? "blocked" : "cancelled", progress: 0, error_code: "AI_APPROVAL_REQUIRED", error_message: null } : job) });
        result = { result: {} };
      } else {
        throw new Error("This action is unavailable in the sample workspace.");
      }
      return result as T;
    },
    async upload() { throw new Error("The sample workspace cannot upload files."); },
  };
}
