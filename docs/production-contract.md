# Unsite — production product contract

Status: launch contract, updated after the September 5 knowledge-first product correction. The current development app implements substantial portions of this contract; it is not yet a customer-ready production service. See development-build.md for verified behavior and remaining setup.

## Product promise

Anyone can give Unsite a collection of writing, creative work, research, business information, project material, documents, notes, or a mixture and receive a coherent, maintained knowledge publication on their own domain, discoverable and retrievable by agents. The customer manages their information through Unsite rather than building and maintaining a conventional website.

Unsite performs the preparation work: extracting information, organizing it into meaningful records, retaining evidence, identifying conflicts, and presenting decisions for review. The customer controls factual corrections, disclosure, publication, and updates.

An existing website is optional. A workspace can contain any subject or mixture of subjects. Its organization follows the material rather than the owner’s industry or identity. The primary human interface is the private owner workspace. Public rendering serves agent retrieval and compatibility; a marketing-site builder is outside the core product.

## Implementation and launch gaps

| Area | Current implementation | Remaining launch requirement |
| --- | --- | --- |
| Preparation | Version-bound AI consent, durable parsing, strict model output, exact source quotes, flexible content types, framing, attribution, qualified summaries, topics and relationship proposals | Configure the provider key and evaluate real extraction quality on representative content; add commercial budgets |
| Ingestion | Private originals, PDF/text/Markdown/JSON and individual static web pages, versioned jobs and retry/cancellation | Hardened crawl egress, multi-page discovery, refresh scheduling, OCR/rendering where needed |
| Knowledge | Stable entries, explicit unknowns/dates/status, custom type labels, source perspectives, typed relationships, comparison suggestions and retained evidence history | Broader conflict evaluation and robust identity resolution across large collections |
| Agent access | Public word-based search, linked Markdown directory, JSON, OpenAPI and a stateless MCP server; saved private retrieval questions | External client walkthroughs, semantic retrieval evaluation where needed, discovery through the custom domain |
| Customer accounts | Supabase customer sessions and database-enforced tenant authorization | Production email configuration, verified signup/recovery, full team/account lifecycle |
| Publishing | Exact reviewed snapshot, immutable releases, release change guards, rollback and unpublish | Domain routing and operational delivery controls |
| Domains | Hosted public API address; portal truthfully reports pending domain integration | Ownership verification, DNS, certificates, routing, removal and transfer handling |
| Workspace | Private sources, review, linked knowledge, retrieval inspection and publication history | Signed-in desktop/mobile accessibility and recovery walkthroughs |
| Operations | Bounded source/model processing and protocol/transaction tests | Billing, rate limits, monitoring, backup/restore drills and load testing |

Passing structural or retrieval checks does not certify factual accuracy or guarantee a model's comprehension. Unsite must preserve qualifications and report missing information without inventing answers.

## Complete customer experience

### 1. Establish the presence

The customer signs up and names a workspace. No person/business preset is required. Onboarding asks for the minimum context needed to begin, accepts an optional existing URL, and allows several documents at once. An empty workspace should make adding material the primary action.

The customer can close the browser and resume. Upload, processing, and review state belong to the account. A failed source does not discard successful sources.

### 2. Prepare the knowledge

Each source receives a durable version and processing status. The pipeline parses readable content, identifies useful material, entities and their context, preserves provenance, and prepares structured proposals.

Examples include an essay’s argument, a fictional scene’s narrator and place within a work, a research finding’s limitations, a recipe’s sequence and units, a specification’s constraints, or a business policy’s conditions. Flexible content type labels and explicit framing distinguish source-reported information, fiction, opinion, procedures, interpretation and mixed material. Attribution identifies the source-established perspective without attributing a narrator’s claims to a real author. Typed fields supplement complete readable content; they must not erase important qualifications in the source.

Every proposed factual assertion must point to supporting source material or an explicit owner-authored statement. Missing information remains unknown. Conflicting prices, dates, or contact details become review decisions. Model-reported confidence alone is not evidence of correctness.

Retrieved and uploaded material is untrusted data. It must not be allowed to alter processing instructions, access credentials, invoke tools, or change publication permissions.

### 3. Review decisions

The customer sees what Unsite learned, where it came from, and what needs attention. Review supports accepting, editing, excluding, merging duplicates, and resolving conflicting claims. The customer can compare an update with both its source and the currently published version.

Public attribution is a separate disclosure decision. The product must not expose original documents, private file names, private source addresses, or hidden notes just because a derived fact is approved.

Review decisions attach to a specific content version. A later source refresh cannot silently undo an owner correction or reuse approval for materially changed content.

### 4. Publish the presence

The customer previews the exact proposed release, connects a domain, and publishes. Domain setup displays the actual verification and HTTPS state, with an actionable next step if either fails.

The domain provides an understandable entry point and stable links to the profile, structured content, readable Markdown, and the API definition. All representations derive from one approved release. The customer should not need to understand JSON to manage the product.

Publication must be resumable and idempotent. An interrupted operation has a recoverable status. A timeout must not leave the owner guessing whether sensitive content became public.

### 5. Maintain the presence

Source refreshes create proposed changes. Owners can review the differences, publish an update, restore an earlier release, export their information, or remove the public presence. Repeated updates retain stable identifiers and addresses.

Usage reporting distinguishes successful reads, failures, and data transferred. Agent attribution must be described as a best-effort inference unless the requester is authenticated; a user-agent string alone cannot prove who accessed the API.

## Production workspace design

The interface should make the customer's presence and pending decisions the main working surface. Developer output is available for inspection when useful.

| Surface | Primary task | Required states |
| --- | --- | --- |
| Overview | Understand what is live and what needs attention | New presence, processing, review required, ready to publish, live, degraded |
| Sources | Add, inspect, refresh, and remove source material | Uploading, queued, parsing, preparing, ready, partial failure, retrying |
| Knowledge | Browse and edit mixed material using content types derived from the collection | Proposed, reviewed, excluded, conflicting, stale |
| Review | Make decisions about new or changed information | Evidence comparison, owner edits, duplicate resolution, publication differences |
| Agent access | Inspect search results, full context, relationships and saved retrieval expectations | Private draft, public release, missing match, stale release, unavailable endpoint |
| Publish | Manage domain and publication | DNS pending, verified, certificate pending, live release, failed operation, rollback |
| Account | Manage access and the service relationship | Account recovery, membership, export/deletion, usage and billing where enabled |

Quality requirements include accessible keyboard operation, responsive layouts, readable source comparisons, saved-edit feedback, understandable errors, and recovery without re-entering work. Adding navigation items or decorative metrics without working behavior does not meet this bar.

## Architecture decisions

### Canonical application state

Use one authoritative application database for accounts, spaces, sources, review decisions, jobs, domains, and releases. Store original files in private object storage. Treat public delivery artifacts as derived data with a recorded release ID.

The current workspace stores its canonical application state in Supabase. A single database transaction creates an immutable release and updates the active pointer; public reads join that pointer. The older D1 prototype is preserved separately. A future domain/CDN publishing pipeline must retain this release identity and add durable reconciliation if it introduces independent writes.

### Core records and invariants

| Record | Responsibility | Invariant |
| --- | --- | --- |
| Account and membership | Identity and access to a space | Every private operation checks membership and permission on the server |
| Workspace | Any collection of material | No industry preset limits content types or relationships |
| Source and source version | Original material and its lineage | Originals are private and versioned; retries do not duplicate uploads |
| Ingestion job | Durable processing and retry state | Attempts have limits, timeouts, cancellation, and a retained failure reason |
| Material and evidence | Prepared content, framing and support | A proposal preserves its source perspective; factual claims identify support or owner authorship |
| Entity and relationship | Typed knowledge and connections | Stable identifiers survive edits and publication changes |
| Review decision | Owner correction and disclosure | Approval identifies the exact reviewed version |
| Release | Immutable publication content | All public representations refer to the same approved release |
| Publication operation | Publish, rollback, or unpublish | Retries converge on the intended state and remain auditable |
| Domain | Ownership, routing, and certificate lifecycle | A hostname cannot serve another customer's private or published state |
| Usage event | Processing and delivery consumption | Limits are enforceable and billing events are idempotent |

### Background preparation

Implement source intake, parsing, extraction, reconciliation, and draft assembly as bounded background jobs. Each step persists its output before advancing. Deduplicate by source version and processing configuration. A retry must not multiply processing charges or silently lose accepted owner edits.

Model and crawl providers sit behind explicit adapters. Validate model output against versioned schemas. Track latency, usage, provider errors, and the configuration that produced a proposal. Public reads serve saved releases and do not require a model call.

### Content and format independence

The knowledge model accepts arbitrary descriptive content types in one collection. Existing kind values remain for compatibility; they must not constrain the owner flow or force new domains into business categories. Source-reported information is not independent factual verification. Creative work and viewpoints are useful content even when they contain no factual assertion.

Format support is implemented through explicit parsing adapters. The current supported formats are PDF, text, Markdown, JSON, pasted text, and a single static public webpage. Supporting any subject is not a claim that arbitrary binary formats already parse. Documents with layout, spreadsheets/tables, audio/video with timestamps, scanned images with OCR, code repositories, archives, and multipage sites need their own extraction, provenance, limits and recovery behavior.

Large collections also need collection-level jobs, hierarchical navigation, cross-source reconciliation, indexed retrieval and cost controls. Current processing is passage-based within each source: 20 MB per upload, up to 300 PDF pages, and 200,000 extracted characters per source. Those limits remain visible and must not be bypassed by silent truncation. Owner-approved asset/file delivery and permissioned email actions are separate future capabilities.

### Production delivery

Maintain a portable application codebase, reviewed migrations, separate development/staging/production configuration, protected secrets, and an automated release pipeline. Hosting must support the customer-account experience, background processing integration, and the full custom-domain lifecycle.

Provider connections do not substitute for runtime credentials, tested integration, or customer ownership of infrastructure. Any service activation with a cost or a domain purchase needs its concrete configuration and cost reviewed before activation.

## Implementation order

These are internal implementation milestones. The complete release includes all core stages.

1. **Application foundation:** customer identity, spaces and membership, canonical schema, private source storage, durable jobs, staging configuration, and account-isolation checks.
2. **Preparation engine:** real document and website intake, extraction into typed records, evidence, duplicate/conflict handling, failure recovery, and evaluation with mixed fiction, essays, research, procedures, technical and business content packs.
3. **Customer workspace:** guided onboarding, real processing states, knowledge editor, review decisions, source comparison, draft persistence, and a publication preview from the approved data.
4. **Presence lifecycle:** immutable releases, public JSON/Markdown/index, domain verification and HTTPS, publish history, source updates, rollback, export, and unpublishing.
5. **Commercial release:** appropriate subscriptions and quotas, operational monitoring, abuse controls, customer support diagnostics, accessibility/browser checks, and restore/recovery verification. Final pricing follows measured usage rather than invented estimates.

## Release gate

Unsite is ready for a customer release when a new customer can independently:

1. Create an account and name a workspace for their material.
2. Supply a realistic collection of documents and URLs, leave, and resume completed or clearly failed processing.
3. Review organized, evidence-supported information and resolve deliberately conflicting source claims.
4. Keep private material out of every public representation.
5. Publish to a domain they control, with ownership verification and working HTTPS.
6. Have an external agent retrieve the publication and correctly answer agreed questions, with missing information handled explicitly.
7. Refresh a source, review the proposed changes, publish an update at the same addresses, and restore or unpublish that release.
8. Remain isolated from a second customer throughout records, files, jobs, domain operations, and exports.
9. Recover from upload interruption, provider timeout, duplicate delivery, and a partially completed publication.

The accepted brief already required source preparation, PDFs, and customer domains. Those requirements remain part of the release. The current prototype does not pass this gate.

## Agent delivery contract

Discovery starts with ordinary reachable resources and stable links. The directory exposes compact summaries; individual records retain the complete explanation, qualifications, typed values, flexible content type, framing, attribution, context dates and relationship targets. Search provides relevant excerpts with links back to those records. JSON, Markdown and MCP read the same immutable publication. A release parameter fences follow-up reads; if the active release changes, the client must rediscover instead of mixing versions. Historical releases stay private.

The llms.txt index is a convenience, not a promise that every agent discovers or uses it. MCP supports compatible server clients; public resources remain available without MCP. Publication dates and edit timestamps are distinct from explicit knowledge-validity dates. Source content never becomes executable agent instructions.

The shared Supabase Edge Function address does not provide normal HTML rendering: the platform rewrites HTML responses unless a custom domain is configured. A customer-domain gateway and plain crawlable HTML/index behavior remain part of domain delivery work. The owner-private portal is not a publicly crawlable substitute for that gateway.
