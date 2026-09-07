"use client";

import { useEffect, useRef, useState, type FormEvent } from "react";
import { Archive, ArrowUpRight, ChevronDown, ChevronRight, FileText, Link2, Plus, RefreshCw, Search, ShieldCheck, Sparkles, UploadCloud, X } from "@/components/unsite/icons";
import { Input } from "@/components/ui/input";
import { Textarea } from "@/components/ui/textarea";
import { Tabs, TabsContent, TabsList, TabsTrigger } from "@/components/ui/tabs";
import { Table, TableBody, TableCell, TableHead, TableHeader, TableRow } from "@/components/ui/table";
import { Sheet, SheetContent, SheetHeader, SheetTitle, SheetDescription } from "@/components/ui/sheet";
import { Skeleton } from "@/components/ui/skeleton";
import type { Source, SourceKind, SourceVersion, SpaceState } from "@/lib/production/types";
import { AI_DISCLOSURE_VERSION } from "@/lib/production/ai-consent";
import { Action, Busy, bytes, Empty, ErrorNotice, External, Field, Modal, Pill, stamp, type Command } from "./shared";
import { CollectionPreparation } from "./collection-preparation";
import { AiPreparationDialog } from "./ai-preparation";
import { liveSourceGateway, type SourceGateway } from "./source-gateway";
import { latestVersion, sourceStatus } from "./source-state";

type SourceDetail = { version: SourceVersion; downloadUrl: string | null };
const sourceKinds = [{ value: "all", label: "All sources" }, { value: "file", label: "Files" }, { value: "url", label: "Links" }, { value: "text", label: "Notes" }] as const;

function mime(file: File) {
  if (/\.md$/i.test(file.name)) return "text/markdown";
  if (/\.txt$/i.test(file.name)) return "text/plain";
  if (/\.json$/i.test(file.name)) return "application/json";
  if (/\.pdf$/i.test(file.name)) return "application/pdf";
  return file.type;
}

export function SourcesSkeleton() {
  return <div className="us-card us-source-skeleton" role="status" aria-label="Loading sources">
    {[0, 1, 2, 3].map(row => <div key={row}><Skeleton className="h-11 w-10 shrink-0" /><div className="flex-1 space-y-2"><Skeleton className="h-4 w-3/5" /><Skeleton className="h-3 w-2/5" /></div><Skeleton className="h-6 w-20" /></div>)}
    <span className="sr-only">Loading your sources…</span>
  </div>;
}

export function AddSource({ spaceId, open, onClose, onSaved, existing, aiAvailable = true, gateway = liveSourceGateway }: {
  spaceId: string; open: boolean; onClose: () => void; onSaved: () => Promise<void>; existing?: Source;
  aiAvailable?: boolean; gateway?: SourceGateway;
}) {
  const [tab, setTab] = useState<SourceKind>(existing?.kind || "file");
  const [title, setTitle] = useState(existing?.title || "");
  const [url, setUrl] = useState(existing?.origin_url || "");
  const [text, setText] = useState("");
  const [files, setFiles] = useState<File[]>([]);
  const [busy, setBusy] = useState(false);
  const [progress, setProgress] = useState("");
  const [error, setError] = useState("");
  const [dragging, setDragging] = useState(false);
  const [aiApproved, setAiApproved] = useState(false);
  const requests = useRef(new Map<string, string>());
  const completed = useRef(new Map<string, string>());

  function requestId(key: string) {
    if (!requests.current.has(key)) requests.current.set(key, crypto.randomUUID());
    return requests.current.get(key);
  }
  function selectFiles(incoming: File[]) {
    if (busy) return;
    const limit = existing ? 1 : 20;
    const invalid = incoming.find(file => !/\.(pdf|md|txt|json)$/i.test(file.name) || file.size < 1 || file.size > 20 * 1024 * 1024);
    if (invalid) { setError(invalid.name + ": choose a nonempty PDF, Markdown, text, or JSON file under 20 MB."); return; }
    setError(incoming.length > limit ? `Choose up to ${limit} file${limit === 1 ? "" : "s"} at a time. The first ${limit} ${limit === 1 ? "is" : "are"} selected.` : "");
    setFiles(incoming.slice(0, limit));
  }
  async function prepareVersion(versionId: string) {
    if (aiApproved && aiAvailable) await gateway.request("/api/app/prepare_source", {
      space_id: spaceId, version_id: versionId, approved: true,
      disclosure_version: AI_DISCLOSURE_VERSION, request_id: requestId("ai:" + versionId),
    });
  }
  async function submit(event: FormEvent) {
    event.preventDefault(); setBusy(true); setError("");
    try {
      if (tab === "file") {
        if (!files.length) throw new Error("Choose at least one file.");
        for (let index = 0; index < files.length; index++) {
          const file = files[index], fileId = file.name + ":" + file.size + ":" + file.lastModified;
          const saved = completed.current.get(fileId);
          if (saved) { await prepareVersion(saved); continue; }
          setProgress(`Saving ${index + 1} of ${files.length}: ${file.name}`);
          const result = await gateway.request<{ result: SourceVersion; upload: { signedUrl: string }; uploadComplete: boolean }>("/api/app/source_intake", {
            space_id: spaceId, title: existing?.title || file.name, kind: "file", mime_type: mime(file),
            byte_size: file.size, request_id: requestId(fileId), ...(existing ? { source_id: existing.id } : {}),
          });
          if (!result.uploadComplete) {
            await gateway.upload(result.upload.signedUrl, file, mime(file));
            await gateway.request("/api/app/complete_upload", { space_id: spaceId, version_id: result.result.id });
          }
          completed.current.set(fileId, result.result.id);
          await prepareVersion(result.result.id);
        }
      } else {
        setProgress("Saving your source…");
        const result = await gateway.request<{ result: SourceVersion }>("/api/app/source_intake", {
          space_id: spaceId, title: title.trim() || (tab === "url" ? new URL(url).hostname : "Untitled note"),
          kind: tab, request_id: requestId(tab + title + url + text), ...(existing ? { source_id: existing.id } : {}),
          ...(tab === "url" ? { origin_url: url } : { text_content: text, mime_type: "text/plain", byte_size: new TextEncoder().encode(text).length }),
        });
        await prepareVersion(result.result.id);
      }
      await onSaved(); onClose();
    } catch (caught) {
      setError((caught as Error).message);
      // Keep partial batch success visible without masking the original error.
      await onSaved().catch(() => {});
    } finally { setBusy(false); setProgress(""); }
  }

  return <Modal open={open} dirty={files.length>0||title!==(existing?.title||"")||url!==(existing?.origin_url||"")||!!text||aiApproved} onClose={() => !busy && onClose()} title={existing ? "Add a new version" : "Add sources"} description={existing ? "Keep the latest context together with its history. Previous versions are preserved." : "Bring your documents, pages, and notes into one private workspace."}>
    <form onSubmit={submit}>
      <fieldset disabled={busy}>
        <Tabs value={tab} onValueChange={value => { if (!existing) { setTab(value as SourceKind); setError(""); } }}>
          <TabsList className="us-source-tabs" aria-label="Source type">
            <TabsTrigger value="file" disabled={!!existing && existing.kind !== "file"}><UploadCloud size={16} />Upload files</TabsTrigger>
            <TabsTrigger value="url" disabled={!!existing && existing.kind !== "url"}><Link2 size={16} />Web page</TabsTrigger>
            <TabsTrigger value="text" disabled={!!existing && existing.kind !== "text"}><FileText size={16} />Paste text</TabsTrigger>
          </TabsList>
          <TabsContent value="file">
            <label className="us-dropzone" data-dragging={dragging} onDragOver={event => { event.preventDefault(); if (!busy) setDragging(true); }} onDragLeave={() => setDragging(false)} onDrop={event => { event.preventDefault(); setDragging(false); selectFiles([...event.dataTransfer.files]); }}>
              <span className="us-upload-icon"><UploadCloud size={22} /></span>
              <strong><em>Click to upload</em> or drag and drop</strong>
              <span>PDF, Markdown, TXT, or JSON · up to 20 MB each</span>
              <input type="file" aria-label="Choose source files" accept=".pdf,.md,.txt,.json" multiple={!existing} onChange={event => { selectFiles([...event.target.files || []]); event.target.value = ""; }} />
            </label>
            {files.length > 0 && <ul className="us-file-queue" aria-label="Selected files">{files.map((file, index) => <li key={file.name + ":" + index}>
              <FileText size={20} className="us-muted" /><span>{file.name}<small>{bytes(file.size)}</small></span>
              <button type="button" className="us-icon-button" aria-label={"Remove " + file.name} onClick={() => setFiles(current => current.filter((_, position) => position !== index))}><X size={16} /></button>
            </li>)}</ul>}
          </TabsContent>
          <TabsContent value="url">
            <Field label="Page URL" hint="One public page per source.">{id => <Input id={id} type="url" placeholder="https://example.com/about" required={tab === "url"} readOnly={!!existing} value={url} onChange={event => setUrl(event.target.value)} />}</Field>
            <Field label="Source name (optional)">{id => <Input id={id} value={title} maxLength={200} onChange={event => setTitle(event.target.value)} placeholder="A name that will be easy to find" />}</Field>
          </TabsContent>
          <TabsContent value="text">
            <Field label="Source name">{id => <Input id={id} required={tab === "text"} value={title} maxLength={200} onChange={event => setTitle(event.target.value)} placeholder="Project notes, an introduction, a useful reference…" />}</Field>
            <Field label="Your text" hint={text.length.toLocaleString() + " / 200,000 characters"}>{id => <Textarea id={id} rows={8} required={tab === "text"} maxLength={200000} value={text} onChange={event => setText(event.target.value)} placeholder="Paste the context you want to keep." />}</Field>
          </TabsContent>
        </Tabs>
        <details className="us-ai-optional">
          <summary><Sparkles size={16} />AI preparation <Pill>Optional</Pill><ChevronDown size={14} /></summary>
          {aiAvailable ? <label className="us-check us-ai-optin"><input type="checkbox" checked={aiApproved} onChange={event => setAiApproved(event.target.checked)} /><span><strong>Prepare these source versions with AI</strong><small>I approve sending their extracted text to OpenAI to create knowledge suggestions. This may include private information. Suggestions stay private until I review and publish them.</small></span></label>
            : <p>Save your sources now. AI preparation can be connected later.</p>}
        </details>
      </fieldset>
      <ErrorNotice message={error} />
      <div className="us-modal-actions"><span className="us-muted us-small"><ShieldCheck size={16} />{gateway.sample ? "Sample data only" : "Private by default"}</span>
        <Action type="submit" disabled={busy || (tab === "file" && !files.length)}>{busy ? <Busy label={progress || "Saving…"} /> : existing ? "Save new version" : "Add sources"}</Action>
      </div>
    </form>
  </Modal>;
}

export function SourceLibrary({ state, canEdit, onAdd, onOpen }: { state: SpaceState; canEdit: boolean; onAdd: () => void; onOpen: (source: Source) => void }) {
  const [query, setQuery] = useState("");
  const [archived, setArchived] = useState(false);
  const [kind, setKind] = useState("all");
  const filtered = state.sources.filter(source => Boolean(source.archived_at) === archived && (kind === "all" || source.kind === kind) && source.title.toLowerCase().includes(query.trim().toLowerCase()));
  const total = state.sources.filter(source => !source.archived_at).length;
  const searching = !!query.trim() || kind !== "all";
  return <>
    <div className="us-section-heading"><div><h1>Sources <span className="us-heading-count">{total}</span></h1><p>The original material behind your knowledge.</p></div>{canEdit && <Action onClick={onAdd}><Plus size={17} />Add sources</Action>}</div>
    <Tabs value={kind} onValueChange={setKind} className="us-source-filter-tabs"><TabsList aria-label="Filter sources by type">{sourceKinds.map(item => <TabsTrigger key={item.value} value={item.value}>{item.label}</TabsTrigger>)}</TabsList></Tabs>
    <div className="us-toolbar">
      <div className="us-search"><Search size={18} /><Input aria-label="Search sources" placeholder="Search sources" value={query} onChange={event => setQuery(event.target.value)} /></div>
      <button type="button" className="us-button-secondary inline-flex items-center" aria-pressed={archived} onClick={() => setArchived(value => !value)}><Archive size={16} />{archived ? "Archived" : "Archive"}</button>
      <span className="us-source-summary"><ShieldCheck size={15} />Originals stay private</span>
    </div>
    {filtered.length ? <div className="us-source-table us-card">
      <Table><TableHeader><TableRow><TableHead scope="col">Source name</TableHead><TableHead scope="col">Status</TableHead><TableHead scope="col">Last added</TableHead><TableHead scope="col"><span className="sr-only">Open source</span></TableHead></TableRow></TableHeader>
        <TableBody>{filtered.map(source => {
          const version = latestVersion(state.versions, source.id), job = state.jobs.find(item => item.source_version_id === version?.id);
          const status = sourceStatus(source, version, job);
          return <TableRow key={source.id}>
            <TableCell><button type="button" className="us-source-title" onClick={() => onOpen(source)}>
              <span className={"us-file-icon us-file-icon-" + source.kind}>{source.kind === "url" ? <Link2 size={20} /> : <FileText size={20} />}</span>
              <span><strong title={source.title}>{source.title}</strong><small>{source.kind === "url" ? source.origin_url : source.kind === "text" ? "Text note" : version ? bytes(version.byte_size) : "File"}{version && <span> · v{version.version}</span>}</small></span>
            </button></TableCell>
            <TableCell><Pill tone={status.tone}>{job?.status === "running" && !source.archived_at && <RefreshCw size={11} className="us-spin" />}{status.label}</Pill><span className="us-status-note">{status.note}</span>{job?.status === "running" && !source.archived_at && <progress aria-label={"Preparation progress for " + source.title} value={job.progress} max={100} />}</TableCell>
            <TableCell><time className="us-row-date" dateTime={version?.created_at || source.created_at}>{stamp(version?.created_at || source.created_at)}</time></TableCell>
            <TableCell><button type="button" className="us-icon-button" aria-label={"Open " + source.title} onClick={() => onOpen(source)}><ArrowUpRight size={18} /></button></TableCell>
          </TableRow>;
        })}</TableBody>
      </Table>
      <div className="us-table-footer"><span>{filtered.length} source{filtered.length === 1 ? "" : "s"}{archived ? " in archive" : ""}</span><span><ShieldCheck size={14} />Version history preserved</span></div>
    </div> : <Empty icon={searching ? <Search size={25} /> : archived ? <Archive size={25} /> : <FileText size={25} />}
      title={searching ? "No sources found" : archived ? "Your archive is empty" : "Your knowledge starts here"}
      description={searching ? "Try another search or show all source types." : archived ? "Sources you archive will appear here. Their originals and version history are preserved." : "Add a document, save a web page, or paste your notes. Everything starts as private context."}
      action={searching ? <Action secondary onClick={() => { setQuery(""); setKind("all"); }}>Clear filters</Action> : !archived && canEdit ? <Action onClick={onAdd}><Plus size={16} />Add your first source</Action> : undefined} />}
  </>;
}

export function Sources({ state, command, reload, canEdit, aiAvailable = true, gateway = liveSourceGateway }: {
  state: SpaceState; command: Command; reload: () => Promise<void>; canEdit: boolean; aiAvailable?: boolean; gateway?: SourceGateway;
}) {
  const [adding, setAdding] = useState(false);
  const [refresh, setRefresh] = useState<Source>();
  const [selectedId, setSelectedId] = useState<string>();
  const [detail, setDetail] = useState<SourceDetail | null>(null);
  const [error, setError] = useState("");
  const [detailError, setDetailError] = useState("");
  const [busy, setBusy] = useState("");
  const [loadingOriginal, setLoadingOriginal] = useState(false);
  const [preparationOpen, setPreparationOpen] = useState(false);
  const [aiDialog, setAiDialog] = useState<{ version: SourceVersion; title: string; mode: "prepare" | "stop" } | null>(null);
  const detailSequence = useRef(0);
  const returnFocus = useRef<HTMLElement | null>(null);
  useEffect(() => () => { detailSequence.current++; }, []);
  const selected = state.sources.find(source => source.id === selectedId);
  const versions = selected ? state.versions.filter(version => version.source_id === selected.id).sort((a, b) => b.version - a.version) : [];

  async function openVersion(version: SourceVersion) {
    const sequence = ++detailSequence.current;
    setLoadingOriginal(true); setDetailError(""); setDetail(null);
    try {
      const result = await gateway.request<SourceDetail>("/api/app/version?id=" + version.id);
      if (sequence === detailSequence.current) setDetail(result);
    } catch (caught) { if (sequence === detailSequence.current) setDetailError((caught as Error).message); }
    finally { if (sequence === detailSequence.current) setLoadingOriginal(false); }
  }
  function closeSource() { detailSequence.current++; setSelectedId(undefined); setDetail(null); setDetailError(""); setLoadingOriginal(false); }
  function openSource(source: Source) {
    returnFocus.current = document.activeElement instanceof HTMLElement ? document.activeElement : null;
    setSelectedId(source.id); setDetail(null); setDetailError(""); setError("");
    const version = latestVersion(state.versions, source.id);
    if (version) void openVersion(version);
  }
  async function act(action: string, payload: Record<string, unknown>) {
    setBusy(action); setError("");
    try { await command(action, payload); if (action === "archive_source" || action === "restore_source") closeSource(); }
    catch (caught) { setError((caught as Error).message); }
    finally { setBusy(""); }
  }

  return <>
    <SourceLibrary state={state} canEdit={canEdit} onAdd={() => setAdding(true)} onOpen={openSource} />
    {!selected && <ErrorNotice message={error} />}
    {!gateway.sample && <details className="us-preparation-section" open={preparationOpen} onToggle={event => setPreparationOpen(event.currentTarget.open)}>
      <summary><Sparkles size={16} />Prepare sources with AI<Pill>Optional</Pill><ChevronDown size={16} /></summary>
      {preparationOpen && <CollectionPreparation state={state} command={command} canEdit={canEdit && aiAvailable} reload={reload} />}
    </details>}
    {(adding || refresh) && <AddSource key={refresh?.id || "new"} spaceId={state.space.id} open onClose={() => { setAdding(false); setRefresh(undefined); }} onSaved={reload} existing={refresh} aiAvailable={aiAvailable} gateway={gateway} />}
    <Sheet open={!!selected} onOpenChange={open => { if (!open) closeSource(); }}>
      <SheetContent side="right" showCloseButton={false} className="us-dialog us-source-sheet" onCloseAutoFocus={event => { event.preventDefault(); if (!refresh) { if (returnFocus.current?.isConnected) returnFocus.current.focus(); else document.getElementById("workspace-content")?.focus(); } }}>
        <button type="button" className="us-icon-button us-panel-close" aria-label="Close source details" onClick={closeSource}><X size={16}/></button>
        <SheetHeader><SheetTitle>{selected?.title || "Source details"}</SheetTitle><SheetDescription>Private source · original content and version history</SheetDescription></SheetHeader>
        {selected && <div className="us-source-sheet-body">
          <div className="us-source-meta"><Pill>{selected.kind === "url" ? "Web page" : selected.kind === "text" ? "Text note" : "Document"}</Pill><Pill>{versions.length} version{versions.length === 1 ? "" : "s"}</Pill>{selected.archived_at && <Pill>Archived</Pill>}{selected.origin_url && <External href={selected.origin_url}>Open page</External>}</div>
          <div className="us-source-detail">
            <section className="us-original"><h3>Original context</h3>
              {loadingOriginal ? <SourcesSkeleton /> : detail ? <>
                <div className="us-between"><span className="us-technical">VERSION {detail.version.version}</span>{detail.downloadUrl && <External href={detail.downloadUrl}>Download</External>}</div>
                <pre>{detail.version.extracted_text || detail.version.text_content || "This version has not been read yet. Its original remains available for download once the upload is complete."}</pre>
              </> : detailError ? <><ErrorNotice message={detailError} /><Action secondary onClick={() => { const version = versions[0]; if (version) void openVersion(version); }}>Try again</Action></> : <Empty icon={<FileText size={24} />} title="No original available yet" description="Complete the upload to view this source." />}
            </section>
            <section className="us-version-history"><h3>Version history</h3>{versions.map(version => {
              const job = state.jobs.find(item => item.source_version_id === version.id);
              const status = sourceStatus(selected, version, job);
              const approved = state.aiAuthorizations.some(auth => auth.source_version_id === version.id && !auth.revoked_at);
              return <div className="us-version" key={version.id} data-selected={detail?.version.id === version.id}>
                <strong>Version {version.version}</strong><small>{stamp(version.created_at)}</small>
                <p><Pill tone={status.tone}>{status.label}</Pill></p>
                {job?.error_message && job.error_code !== "AI_APPROVAL_REQUIRED" && <div className="us-notice">{job.error_message}</div>}
                <div className="us-inline-actions">
                  <button type="button" onClick={() => void openVersion(version)} aria-current={detail?.version.id === version.id ? "true" : undefined}>View original<ChevronRight size={14} /></button>
                  {canEdit && aiAvailable && job && job.status !== "completed" && (!["queued", "running"].includes(job.status) || !approved) && !selected.archived_at && <button type="button" disabled={!!busy} onClick={() => setAiDialog({ version, title: selected.title, mode: "prepare" })}><Sparkles size={14} />{approved ? "Retry preparation" : "Prepare with AI"}</button>}
                  {canEdit && job && ["failed", "cancelled"].includes(job.status) && !approved && !selected.archived_at && <button type="button" disabled={!!busy} onClick={() => void act("retry_job", { job_id: job.id })}><RefreshCw size={14} />Retry reading</button>}
                  {canEdit && job && approved && !selected.archived_at && <button type="button" disabled={!!busy} onClick={() => setAiDialog({ version, title: selected.title, mode: "stop" })}><X size={14} />Stop AI preparation</button>}
                  {canEdit && job && ["queued", "running"].includes(job.status) && !approved && <button type="button" disabled={!!busy} onClick={() => void act("cancel_job", { job_id: job.id })}><X size={14} />Cancel reading</button>}
                </div>
              </div>;
            })}</section>
          </div>
          <ErrorNotice message={error} />
          {canEdit && selected.archived_at && <div className="us-source-sheet-actions"><Action secondary disabled={!!busy} onClick={() => void act("restore_source", {source_id:selected.id})}><Archive size={16}/>{busy==="restore_source"?"Restoring…":"Restore source"}</Action><span className="us-small us-muted">All original versions are retained.</span></div>}
          {canEdit && !selected.archived_at && <div className="us-source-sheet-actions"><Action secondary disabled={!!busy} onClick={() => { setRefresh(selected); closeSource(); }}><Plus size={16} />Add version</Action><button type="button" className="us-link" disabled={!!busy} onClick={() => void act("archive_source", { source_id: selected.id })}><Archive size={15} />{busy === "archive_source" ? "Archiving…" : "Archive source"}</button></div>}
        </div>}
      </SheetContent>
    </Sheet>
    {aiDialog && <AiPreparationDialog {...aiDialog} command={command} onClose={() => setAiDialog(null)} />}
  </>;
}
