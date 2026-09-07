# Collection preparation

This update implements a persistent collection coordinator, shared evidence, bounded source readers, an AI curator, a separate AI verifier, and owner review. Its database and both backend functions are now deployed to the new Macfarlane Unsite project `taikoetkfginjymihxpf`. The replacement portal is not deployed and the provider key remains absent. See `resume-unsite.md` for the current deployment state.

The production build, TypeScript checks, and all 40 local tests passed in the implementation session. All five database integration suites now pass on the new project. The collection suite found ambiguous source-item columns in planning and curation coverage; these were qualified and the suite passed after the corrective migration. Mocked-provider tests and SQL fixtures do not establish real model quality.

## Data and workflow

A run freezes selected source version IDs, a goal, and the current approved knowledge snapshot. Its explicit disclosure covers sending selected text, extracted suggestions, and relevant approved knowledge to OpenAI. Individual-source consent is separate. Inputs and previous approved records are never silently replaced with newer versions.

Parsed PDF, text, Markdown, JSON and web-page content receives canonical 12,000-character evidence segments with source version IDs and zero-based Unicode character offsets. The complete text is retained. Segments use honest character locators; PDF page markers remain in extracted text. Parsed version text becomes immutable. No OCR or new file-format adapter is included.

The durable task graph is:

1. Wait for supported source parsing, then extract each evidence segment with the source reader.
2. Use ordinary code to route every extracted item into bounded groups. Title, alias and topic overlap is a routing heuristic, not an identity or merge decision. Every extracted item must be assigned exactly once. At most four relevant complete approved records are included per group; this is not exhaustive semantic comparison across the entire knowledge store.
3. Curate additions and suggested updates. Every input item must appear in proposals or an explicit unresolved note. Exact quotes must reference selected canonical segments; update targets must be in the frozen approved set provided to that task.
4. Verify the proposals against their full supplied evidence and prior approved context. Verdicts are supported, needs review or unsupported. This assesses supplied evidence, not independent truth. Verification does not rewrite proposals.
5. Expose proposals in Review after all collection tasks complete. Concerns require owner acknowledgement. Existing record updates use current revision checks. Accepted evidence history is retained. Publishing continues through the existing explicit immutable-release command; private evidence and orchestration data never enter the public projection.

No model has a publishing, emailing or file-delivery tool. Provider requests disable response storage. Curation and verification use distinct instructions and separate requests with the same configured model initially.

## Boundaries and recovery

A run supports one to eight source versions, up to 80 segments (about 960,000 characters), up to 200 existing approved entries and a 1.2 MB frozen knowledge snapshot. Existing individual-source limits remain 20 MB, 300 PDF pages and 200,000 extracted characters. The planner caps total extracted items at 1,000, with at most 20 items and four segments per group and at most 90,000 serialized characters before approved comparisons. Each group has at most 55,000 characters of approved comparison records.

Owners choose a cap of 1–200 reserved provider requests per run, default 40. This is a request cap, not a currency cap. Both preparation paths share a locked rolling budget of 50 workspace and 200 service requests per 24 hours. Failed and uncertain reservations count. Recorded token usage can be incomplete after interruptions or invalid provider responses.

One task per run is active at a time. Each invocation makes at most one model request and checkpoints its result. Leases last 150 seconds; known rate limits use bounded retry delays. Unknown provider outcomes block the run for explicit retry and never silently repeat a possible paid request. Resume retains finished tasks. Cancellation revokes authorization and fences future dispatch/checkpoints; already sent requests may finish and their usage can still be recorded. Archival of any selected source pauses the run.

The named cron schedule now considers collection runs as well as individual source jobs. Without that change, a collection using already-parsed sources would stall after its first worker invocation.

## Owner workspace

Sources contains a collection card, source selection and run-level disclosure. Runs show phase counts, request usage, fixed source versions, newer-version notices, unresolved notes, and stop/resume controls. Polling stops when no run is active and is cleaned up on unmount. Evidence quotes in Review open complete private canonical passages. Suggested updates offer comparison with the current approved entry; changed revisions are highlighted.

The primary account workspace, source upload and owner publication flows retain their existing design. API, Markdown and MCP still expose approved releases only.

## Deployment state

Source schema: `supabase/pending/collection-coordination.sql`. It remains pending for the original project, while the new project received it within an initial bootstrap followed by a coverage correction. Exact new-project migration history is stored under `supabase/deployments/taikoetkfginjymihxpf/`. Do not reapply the pending file or historical migrations to that initialized target. The portal's review queue requires the verified `review_ready` column.

`tests/collection-coordination.sql` is a rollback-only integration suite covering run consent, tenant isolation, immutable evidence, source references, item coverage, verification, owner revision conflicts, private projection, request caps, cancellation and ambiguous-outcome recovery. It passed on the new managed database after the source-item column correction. All fixtures rolled back.

The original development project is xwqjunvwimkqtumhbyre. A connector workspace change does not itself move, delete or reset that project. Verify the intended target before applying anything. The prior deployment remains the live development app until a compatible backend update is verified.

For another empty project, use the [fresh deployment procedure](fresh-deployment.md); the Macfarlane destination is already initialized. Vercel now exposes tools, but lists no teams and automatic approval review rejected deployment to an unverified destination. No Vercel deployment has occurred. The reproducible `scripts/prepare-vercel.mjs` generator adapts the portal to Next.js with server-only environment configuration and dynamic account/API routes. The generated Next.js build passed previously; portal source has not changed. The original Sites app remains live on its original backend.
