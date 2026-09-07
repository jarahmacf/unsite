# Unsite development build — 5 September 2026

This is the first implementation of the production contract, not a production-readiness claim. The contract in `production-contract.md` remains the launch scope.

## Implemented

- Customer email/password sessions using Supabase Auth and server-managed, HTTP-only cookies. Confirmation callback, resend confirmation, password recovery and local sign-out are implemented. Account identity comes from a verified customer session, not an email supplied in a header.
- Person/business presences with ownership and membership roles. The current UI manages the owner’s presences; team invitations and role administration are not implemented yet.
- Tenant-isolated Postgres tables and guarded transactional commands. Customer clients have read access under RLS; narrow commands enforce identity, role and optimistic revisions for mutations. Anonymous users cannot read private tables.
- Private uploads of PDF, text, Markdown and JSON; text notes and imports of individual public HTML pages. Sources have immutable originals and numbered versions. Upload completion is checked against the stored object size, and retries reuse their request IDs.
- Durable jobs with leases, retries, cancellation and saved parsing checkpoints. A scheduled worker wakes each minute when there is eligible work. An open browser is not required. Parsing runs inside Supabase; sending extracted text to OpenAI requires a separate recorded approval for that exact source version.
- Optional, initially unchecked AI preparation during intake and an explicit approval dialog in source history. Approvals record the customer, provider, disclosure version and time. New versions do not inherit approval. Stopping preparation revokes approval and fences unfinished results; text already sent cannot be recalled.
- Audited provider attempts with model, response ID, token usage and outcome. Dispatch reserves capacity and checks current consent under a database lock. Rolling 24-hour development limits are 50 reserved requests per workspace and 200 across the service. An interrupted request with an unknown outcome pauses for customer review instead of being sent again automatically.
- A source library, original text/download views, knowledge editing with typed fields, evidence review and explicit updates to existing stable records. Model-generated suggestions have no public effect until accepted and published.
- Immutable releases assembled in one database transaction from approved active records and presence details. Explicit publication review, repeat-request idempotency, release export, rollback and unpublishing are implemented.
- Public v2 manifest, profile, paginated/filterable records, stable record URLs, JSON bundle, Markdown, discovery index and OpenAPI definition. Public reads join only the active release. Drafts, evidence and private source locations are not part of a release.

## Deployed processing boundary

The user explicitly authorized OpenAI preparation for sources customers choose to process. The AI-capable worker is now deployed with JWT gateway validation, an independent scoped worker credential and per-source-version customer approval. Merely uploading a source or configuring a key does not authorize an AI request.

The worker imports `parser.ts`, `crawler.ts`, `processing.ts` and `prepare.ts`. Without customer approval it stops after parsing with a ready-to-prepare state. With approval but no provider key it records a setup-pending state. Consent is checked again immediately before each reserved provider request. Requests already dispatched may finish after cancellation; cancellation prevents their results from becoming new suggestions and prevents further dispatches.

`supabase/functions/unsite-worker/prepare.ts` uses the OpenAI Responses API with strict structured output and `store: false`, treats source text as untrusted data, and verifies each evidence quotation against the supplied passage. `store: false` disables response storage; it is not a claim about all provider retention. Tests use mocked provider responses; no real model preparation has been executed. Verbatim quote matching does not establish semantic correctness, so owner review remains necessary.

The deployed worker health check confirms that `OPENAI_API_KEY` is missing. Add an account-owned key in [Supabase function secrets](https://supabase.com/dashboard/project/xwqjunvwimkqtumhbyre/functions/secrets). Keep the value out of source control and chat. No redeployment is required after setting the secret. Refresh the portal's connection status, then use Prepare with AI or Retry AI preparation on a selected source version. Blocked jobs are not silently restarted by adding a key. Verify actual preparation with non-sensitive material before customer onboarding.

The default model is pinned to `gpt-5-mini-2025-08-07`; a supported Responses model can be selected with the optional `UNSITE_MODEL` function secret. The 50/200 request limits are conservative development controls, not a complete billing or token-budget system.

## Setup required before customer sign-up can be validated

The connected Supabase tools do not expose Auth configuration or function secret management. In the project dashboard:

1. Set the Auth Site URL to the current portal origin: `https://port-agent-websites.workspace-106208.chatgpt.site`.
2. Add redirect allowlist entries for `https://port-agent-websites.workspace-106208.chatgpt.site/auth/callback` and `https://port-agent-websites.workspace-106208.chatgpt.site/auth/callback?next=/account/recover`. Retain email confirmation.
3. Configure production SMTP and the sending domain. Test signup, confirmation, resend, password recovery, session renewal and sign-out with an account the tester controls. Default email-service restrictions are not a launch email solution.
4. The current Site is an owner-private development portal with an additional platform access gate. Customer launch needs a separately approved public portal origin and matching Auth redirects. Do not broaden this preview's audience implicitly.

Dashboard: <https://supabase.com/dashboard/project/xwqjunvwimkqtumhbyre/auth/url-configuration>

## Runtime and deployment

The current application code remains in the existing Sites Git repository. The `jarahmacf/unsite` GitHub repository was not accessible when this work began; no unrelated repository was modified. Once an intended GitHub repository exists and is accessible, mirror this source and establish its CI/review workflow.

Runtime values are managed outside source control:

| Runtime | Configuration |
| --- | --- |
| Portal | `UNSITE_SUPABASE_URL`, `UNSITE_SUPABASE_PUBLISHABLE_KEY`, `UNSITE_APP_ORIGIN` |
| Worker invocation | `UNSITE_WORKER_TOKEN`, `UNSITE_WORKER_GATEWAY_KEY` |
| Supabase Vault | `unsite_worker_key`, `unsite_worker_gateway`, `unsite_worker_url` |
| Worker database access | Supabase-managed server credentials, never exposed to the client |
| OpenAI preparation | Required `OPENAI_API_KEY`; optional `UNSITE_MODEL` override; per-version approval remains mandatory |

Use `supabase/worker-schedule.sql` to reproduce the named queue schedule after configuring Vault. Rotate the scoped invocation secret in the credential hash table, Vault and portal together. Cron transports no source payload.

Migrations match the hosted migration history. Existing D1/prototype migrations and the v1 public API are preserved. The former manual portal is available at `/prototype`; the earlier Port experiment is at `/legacy`. Customer workspace data is held in Supabase, not D1.

## Verification completed

- TypeScript checking and the optimized application build pass.
- Twenty-nine production, linked-knowledge and universal-content tests cover customer-session enforcement, cross-origin writes, input/disclosure limits, complete chunking, exact evidence checks, malformed model output, provider interruption behavior, crawl guards, release diffs, v2 delivery, consent checks, dispatch denial and usage checkpoints. Two existing suites continue to pass. The linked-knowledge suite additionally covers alias retrieval, context validation, preserved uncertainty, release-fenced record links, directory pagination, MCP lifecycle/resource/tools, origin/body guards, arbitrary-fetch denial and unpublishing.
- `tests/production-isolation.sql` ran against Postgres with rolled-back fixtures. It verifies account isolation, denial of direct writes, idempotent source/record/release operations, stale-write rejection, private-source exclusion, release immutability, rollback, unpublishing, lease fencing and reviewed updates to stable records.
- `tests/ai-authorization.sql` ran against Postgres with rolled-back fixtures. It verifies explicit consent, tenant isolation, service-only dispatch, idempotent approval and dispatch, revocation, rejected replay after revocation, result fencing, fresh consent for new versions and uncertain-attempt recovery. No provider calls are made by these SQL tests.
- The deployed AI-capable worker answered an authenticated health request with `worker: true, model: false, modelName: "gpt-5-mini-2025-08-07", consentRequired: true`; the queue schedule is active. The missing key is the current provider-connection blocker.
- No signed-in browser walkthrough or customer confirmation-email round trip has been performed. These remain necessary before customer onboarding is claimed to work end to end.

The security advisor now reports no warning or error findings. Its sole informational result is intentional policy-free RLS on the service-only worker credential table. An initial `pg_net` namespace warning was resolved by reinstalling the new extension into the supported `extensions` namespace while the source and network queues were verified empty, without CASCADE or catalog edits.

## Remaining production contract work

- Actual model preparations and review quality, broader conflict/identity evaluation beyond name/alias comparisons and shared-field differences, and commercial token/cost budgets per customer.
- Hardened crawl egress, multi-page discovery, rendering support and OCR where required. Current imports are individual static HTML pages, with HTTPS/public-DNS, robots, redirect and response-size checks. DNS preflight is not a substitute for a hardened egress service.
- Full account lifecycle, team management and customer-controlled deletion/export of all private data, with object cleanup and retention.
- Custom-domain ownership verification, DNS guidance/provisioning, certificate lifecycle, hostname routing, disconnect/reconnect and monitoring. The UI does not pretend these are connected.
- Commercial onboarding, billing/entitlements, model/storage budgets, rate controls, operational monitoring, backup/restore drills and load testing.
- Signed-in desktop/mobile accessibility and recovery walkthroughs, external-agent compatibility checks, and production email delivery verification.

Source-backed knowledge and customer domains remain central product work, not optional enhancements.

## Implementation references

- [Supabase server-side Auth](https://supabase.com/docs/guides/auth/server-side/creating-a-client)
- [Supabase signed uploads](https://supabase.com/docs/reference/javascript/storage-from-createsigneduploadurl)
- [Supabase scheduled network calls](https://supabase.com/docs/guides/database/extensions/pg_net)
- [OpenAI structured outputs](https://developers.openai.com/api/docs/guides/structured-outputs)
- [OpenAI GPT-5 mini model and snapshots](https://developers.openai.com/api/docs/models/gpt-5-mini)
- [Supabase function secrets](https://supabase.com/docs/guides/functions/secrets)
- [unpdf](https://github.com/unjs/unpdf)

## Linked knowledge and agent access update

Existing spaces retain their compatibility kind values; new workspaces start as collections without requiring an identity preset. Reviewed entries carry summaries, aliases, topics, explicit current/historical/uncertain status, optional as-of dates and typed relationships. Missing dates remain unknown. Public projections preserve explicit null structured values. New source suggestions require exact evidence for proposed relationships; names are resolved to approved record IDs only through owner review.

The review workspace compares potential overlaps in approved knowledge and other proposals. Shared structured fields with differing values appear for manual review, without declaring that either claim is correct. Updating an existing entry preserves its stable ID and requires its current revision. Source evidence from previously accepted candidates remains visible in private review history. Keeping an existing entry or combining descriptions is an explicit owner choice.

The Agent access workspace offers a connected directory, full-record inspection, draft/public search and up to 20 saved questions with expected entries or no match. Draft checks run on approved private state. Published checks contact the actual public manifest, release-pinned bundle and search endpoint. Reports explain their scope: deterministic retrieval/structure checks, not an LLM evaluation or factual certification.

Publication previews now use the same complete database projection as publishing and submit the reviewed draft revision. A concurrent edit blocks publication until the owner reviews again. Schema 2.1 adds context and relationships; old schema 2.0 releases remain readable. Public delivery now includes /search, /catalog.md, /topics and /mcp. Search matches normalized words and weights title/alias/topic/summary hits; it does not provide embeddings or generated answers. Search results, relationship links and MCP resource URIs are pinned to the current release. An old release request returns 409, not a private historical snapshot.

MCP is a small stateless Streamable HTTP implementation supporting protocol versions 2025-03-26, 2025-06-18 and 2025-11-25. It exposes read-only search/fetch tools and published resources, accepts initialization/notifications, rejects all browser Origins, limits request bodies to 32 KB and never fetches a caller-supplied URL. No SSE sessions or write tools are advertised. Protocol handler tests pass; an independent external MCP client walkthrough is still required before claiming broad client compatibility.

The linked-knowledge migration was tested against the hosted database with rollback-only fixtures. The new tests verify tenant isolation, same-space relationship targets, atomic failed updates, preserved source lineage, exact snapshot publication, stale-preview rejection, explicit nulls, excluded relationship targets, immutable older releases and bounded private retrieval cases. They caught and prompted two corrective migrations for PL/pgSQL variable qualification; the final isolation, AI-authorization and linked-knowledge suites pass. The installed Supabase CLI was unavailable and network approval for its package download was cancelled before a decision; migrations were applied through the authorized native migration API and saved with the actual server-assigned history versions.

The current shared Supabase function hostname serves the public Markdown/JSON/MCP interfaces. It cannot stand in for custom-domain HTML delivery: Supabase rewrites HTML responses on the shared function domain. Domain verification/routing/certificates and a crawlable domain index remain launch work. No domain was connected or purchased during this update.

The provider key remains absent. No real OpenAI preparation, external-model comprehension test, customer email round trip, or signed-in browser walkthrough has been performed.


## Domain-independent material update

The owner names a collection and can mix any subject matter within it. Entry types are free descriptive labels rather than a required industry/category selector. Knowledge cards and filters reflect the types present in the loaded collection. Owners can explicitly choose any approved entry as an update target; automatic comparisons still use conservative legacy-kind and name/alias matching and never merge records.

Optional schema 2.1 context fields now include type_label (100 characters), framing (source_claim, opinion, fiction, instruction, interpretation, mixed, or unspecified), and attribution (600 characters). Prior contexts and schema 2.0/2.1 releases remain readable. Framing labels describe source meaning and do not certify truth. Unknown speakers and dates remain unspecified.

The model preparation prompt now accepts creative and nonfactual material and asks for source-established perspectives, coherent sequences, conditions and qualifications. It explicitly separates fictional narrators/characters from real authors. Structured output preserves native number, boolean and null field values. Verification rejects duplicate/unsafe keys, invalid metadata, nested field values and unsupported source quotations. These checks validate structure and quote presence, not whether a model correctly understood the work.

Review and publication previews display framing and attribution. Every public record carries the metadata; Markdown places it before the material, and catalogs/search/MCP retain it. Discovery lists available content types. HTTP search and records/catalog support case-insensitive type filters, and MCP search exposes the same filter. Retrieval indexes type labels and attribution alongside existing title/alias/topic/summary/content words. Checks no longer request factual freshness dates for fiction, viewpoints or procedures.

Seven added local tests use mixed fiction, company policy, recipe, research and essay fixtures. They cover input validation and legacy compatibility, primitive field preservation, duplicate-key and evidence rejection, the mocked provider boundary, HTTP/MCP semantic delivery, filtering, interpretation changes in release review, and preservation of separate perspectives when explicitly combining descriptions. The rollback-only universal-knowledge SQL suite verifies the same metadata through authenticated database writes, exact immutable publication and tenant isolation. No real provider processing or comprehension evaluation has been performed.

This is a subject-independent foundation with bounded supported formats. It does not add DOCX/spreadsheet/media/OCR/archive adapters, multipage crawling, collection-level ingestion/reconciliation, file delivery, email actions, or custom domains. The current source limits remain 20 MB per upload, 300 PDF pages, and 200,000 extracted characters. Provider credentials, customer Auth/email validation and the other launch gaps above remain outstanding.


## Collection coordination implementation and Macfarlane backend

The collection coordinator, shared canonical evidence, bounded extraction/curation/verification tasks and owner workspace controls are implemented. TypeScript checks and mocked provider/contract tests passed. Supabase access recovered in the continuation, and the new Macfarlane Unsite project `taikoetkfginjymihxpf` now has the schema, both backend functions, scoped worker credentials and a combined source/collection schedule. All five rollback-only SQL suites pass after correcting ambiguous source-item columns in the collection coverage queries. Deployed health checks verify public access and both worker credential boundaries; model configuration remains absent.

See `collection-coordination.md` for workflow limits and `resume-unsite.md` for actual target migration versions and remaining tasks. The generated Next.js production build passed previously and its source is unchanged. Vercel tools now respond, but list no teams and automatic approval review rejected deployment to an unverified destination. The replacement portal, real account/email flows and actual model processing remain unverified. The original Sites app and its original backend remain unchanged.
