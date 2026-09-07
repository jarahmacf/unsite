import { test } from "node:test";
import assert from "node:assert/strict";
import { createRequire } from "node:module";
import { fileURLToPath } from "node:url";

const root = fileURLToPath(new URL("..", import.meta.url)).replace(/\/$/, "");
const { build } = createRequire(root + "/package.json")("esbuild");
const compiled = await build({ stdin: { contents: `export * from ${JSON.stringify(root + "/app/demo/fixtures.ts")}; export * from ${JSON.stringify(root + "/components/unsite/source-state.ts")}; export * from ${JSON.stringify(root + "/app/demo/workspace-gateway.ts")};`, loader: "ts", resolveDir: root }, bundle: true, format: "esm", platform: "node", write: false, tsconfig: root + "/tsconfig.json", logLevel: "silent" });
const { sampleState, sampleGateway, latestVersion, sourceStatus, workspaceGateway } = await import("data:text/javascript;base64," + Buffer.from(compiled.outputFiles[0].text).toString("base64"));

test("sample source workflow preserves versions and never falls back to a live service", async () => {
  let state = sampleState(true);
  const gateway = sampleGateway(() => state, next => { state = next; });
  const originalFetch = globalThis.fetch;
  let outgoing = 0;
  globalThis.fetch = async () => { outgoing++; throw new Error("Live request from preview"); };
  try {
    const first = await gateway.request("/api/app/source_intake", { request_id: "first", kind: "text", title: "Studio notes", text_content: "First version" });
    const retry = await gateway.request("/api/app/source_intake", { request_id: "first", kind: "text", title: "Studio notes", text_content: "First version" });
    assert.equal(retry.result.id, first.result.id);
    assert.equal(state.sources.length, 1);
    const second = await gateway.request("/api/app/source_intake", { request_id: "second", source_id: first.result.source_id, kind: "text", title: "Studio notes", text_content: "Revised version" });
    assert.equal(second.result.version, 2);
    assert.equal(state.sources.length, 1);
    assert.equal(state.versions.length, 2);
    const original = await gateway.request("/api/app/version?id=" + first.result.id);
    assert.equal(original.version.text_content, "First version");
    assert.equal(original.downloadUrl, null);
    await gateway.request("/api/app/archive_source", { source_id: first.result.source_id });
    assert.ok(state.sources[0].archived_at);
    assert.equal(state.versions.length, 2);
    for (const path of ["/api/auth", "/api/app/prepare_source", "/api/app/start_collection_run", "/api/app/publish_release"]) {
      await assert.rejects(gateway.request(path, {}), /unavailable/);
    }
    await assert.rejects(gateway.upload("https://example.invalid/upload", {}, "text/plain"), /cannot upload/);
    assert.equal(outgoing, 0);
  } finally { globalThis.fetch = originalFetch; }
});

test("source status identifies the latest saved version without treating optional AI consent as an error", () => {
  const state = sampleState();
  const source = state.sources[0];
  const first = state.versions[0];
  const newer = { ...first, id: "newer", version: 2 };
  assert.equal(latestVersion([first, newer], source.id).id, "newer");
  assert.equal(latestVersion([newer, first], source.id).id, "newer");
  assert.equal(sourceStatus(source, first, state.jobs[0]).label, "Saved");
  assert.equal(sourceStatus(source, first, state.jobs[0]).tone, "neutral");
  assert.equal(sourceStatus({ ...source, archived_at: first.created_at }, first, { ...state.jobs[0], status: "failed" }).label, "Archived");
});

test("sign-in-free workspace edits, review, retrieval and releases stay local", async () => {
  let state = sampleState();
  const gateway = workspaceGateway(() => state, next => { state = next; });
  const originalFetch = globalThis.fetch;
  let outgoing = 0;
  globalThis.fetch = async () => { outgoing++; throw new Error("Live request from demo"); };
  try {
    const initial = await gateway.request("/api/app/knowledge?space=" + state.space.id);
    assert.equal(initial.snapshot.records.length, 3);
    const record = state.records[0];
    const detail = await gateway.request("/api/app/record?id=" + record.id);
    assert.equal(detail.record.id, record.id);
    await gateway.request("/api/app/edit_record", { record_id: record.id, revision: record.revision, title: "Updated sample title", text: record.text, fields: {}, links: [] });
    assert.equal(state.records[0].title, "Updated sample title");
    await assert.rejects(gateway.request("/api/app/edit_record", { record_id: record.id, revision: 1 }), /changed/);
    const candidate = state.candidates[0];
    await gateway.request("/api/app/review_candidate", { candidate_id: candidate.id, revision: candidate.revision, decision: "accept", title: candidate.title, text: candidate.text, kind: candidate.kind, context: candidate.context });
    assert.equal(state.candidateCount, 0);
    assert.equal(state.recordCount, 4);
    await gateway.request("/api/app/update_space", { revision: state.space.content_revision, name: "Edited sample workspace", description: "Local sample", contact_email: "" });
    assert.equal(state.space.name, "Edited sample workspace");
    const report = await gateway.request("/api/app/agent-check?mode=draft");
    assert.equal(report.transport, null);
    assert.equal(report.inspection.record_count, 4);
    const revision = state.space.content_revision;
    const published = await gateway.request("/api/app/publish_release", { revision, reviewed: true, request_id: "sample-release" });
    const retry = await gateway.request("/api/app/publish_release", { revision, reviewed: true, request_id: "sample-release" });
    assert.equal(published.result.id, retry.result.id);
    assert.equal(state.releases.length, 1);
    assert.equal(state.space.content_revision, revision);
    const release = await gateway.request("/api/app/release?id=" + published.result.id);
    assert.equal(release.release.data.records.length, 4);
    assert.ok(!JSON.stringify(release.release.data).includes("source_versions"));
    await gateway.request("/api/app/unpublish", { reviewed: true });
    assert.equal(state.space.active_release_id, null);
    await gateway.request("/api/app/rollback_release", { reviewed: true, release_id: published.result.id });
    assert.equal(state.space.active_release_id, published.result.id);
    for (const path of ["/api/auth", "/api/app/prepare_source", "/api/app/start_collection_run", "https://example.invalid/private"]) {
      await assert.rejects(gateway.request(path, {}), /unavailable/);
    }
    await assert.rejects(gateway.upload("https://example.invalid/upload", {}, "text/plain"), /cannot upload/);
    assert.equal(outgoing, 0);
  } finally { globalThis.fetch = originalFetch; }
});

test("workspace controls and full knowledge search run without live requests in the demo",async()=>{
  let state=sampleState();const gateway=workspaceGateway(()=>state,next=>{state=next;});
  const originalFetch=globalThis.fetch;let outgoing=0;globalThis.fetch=async()=>{outgoing++;throw new Error("Unexpected live request");};
  try{
    const source=state.sources[0];const originals=structuredClone(state.versions);
    await gateway.request("/api/app/archive_source",{source_id:source.id});
    await gateway.request("/api/app/restore_source",{source_id:source.id});
    assert.equal(state.sources[0].archived_at,null);assert.deepEqual(state.versions,originals);
    const beforeRevision=state.space.content_revision;
    const settings=await gateway.request("/api/app/workspace-settings");assert.equal(settings.members[0].role,"owner");
    const invitation=await gateway.request("/api/app/create_invitation",{email:"Teammate@example.com",role:"viewer",request_id:"sample-invite",token:"a".repeat(64)});
    const retry=await gateway.request("/api/app/create_invitation",{email:"Teammate@example.com",role:"viewer",request_id:"sample-invite",token:"a".repeat(64)});
    assert.equal(retry.result.id,invitation.result.id);assert.equal(invitation.result.email,"teammate@example.com");
    await gateway.request("/api/app/revoke_invitation",{invitation_id:invitation.result.id});
    const after=await gateway.request("/api/app/workspace-settings");assert.ok(after.invitations[0].revoked_at);
    await gateway.request("/api/app/update_member",{user_id:"sample-editor",role:"viewer"});
    assert.equal((await gateway.request("/api/app/workspace-settings")).members[1].role,"viewer");
    await assert.rejects(gateway.request("/api/app/remove_member",{user_id:"sample-owner"}),/Owner/);
    assert.equal(state.space.content_revision,beforeRevision,"access changes do not change publication revision");
    const exemplar=state.records[0];state={...state,records:Array.from({length:205},(_,n)=>({...exemplar,id:"directory-"+n,title:"Entry "+n,text:n===204?"needle outside initial page":"Fixture content",active:n!==204})),recordCount:205};
    const found=await gateway.request("/api/app/record-directory?q=needle&inclusion=excluded");assert.equal(found.count,1);assert.equal(found.items[0].id,"directory-204");
    const page=await gateway.request("/api/app/record-directory?offset=200&limit=24");assert.equal(page.count,205);assert.equal(page.items.length,5);
    const exportData=await gateway.request("/api/app/workspace-export");assert.equal(exportData.records.length,205);assert.equal(exportData.sample,true);assert.ok(!JSON.stringify(exportData).includes("storage_path"));
    const activity=await gateway.request("/api/app/activity?offset=0");assert.ok(activity.count>=4);
    for(const path of ["/api/auth","/api/app/accept_invitation","/api/app/prepare_source"]){await assert.rejects(gateway.request(path,{}),/unavailable/);}
    assert.equal(outgoing,0);
  }finally{globalThis.fetch=originalFetch;}
});
