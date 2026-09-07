# GEO delivery and launch

Unsite's product goal is to become an entity's preferred, attributable source when an external AI system answers relevant questions or needs its resources. This release builds authority, discovery, public retrieval, source maintenance, and measurement around the existing owner-reviewed publishing model.

## What is served

| Surface | Address | Behavior |
| --- | --- | --- |
| Canonical publication | `https://unsite.vercel.app/p/SPACE_UUID` | Server-rendered introduction, identity, entry directory and approved resources |
| Canonical entry | `/p/SPACE_UUID/records/RECORD_UUID` | Complete text, structured details, framing, dates and relationships |
| HTTP API | `https://PROJECT.supabase.co/functions/v1/unsite/v2/SPACE_UUID` | Release discovery, indexed search, individual reads, approved resources, current domain proof |
| MCP | API base + `/mcp` | Stateless read-only `search`, `fetch`, `list_resources`, and record resources |
| Portable representations | `/index.md`, `/catalog.md`, `/bundle.json`, `/llms.txt` | The same approved release in other formats |
| Public discovery | `/directory`, `/robots.txt`, `/sitemap.xml` | Active publications and canonical entry pages only |

These are callable APIs backed by a database. Markdown and JSON exports complement them. An MCP client must be configured with the endpoint; ordinary web discovery does not automatically install a tool connection. Resource entries describe public URLs; linked files can change independently. Use versioned URLs when a fixed external artifact is required. Unsite does not advertise booking, purchasing, messaging or other transactional capabilities it has not implemented.

## Publisher authority

In Visibility → Identity, select the entity type and provide its official website, established alternate names and official profile URLs. Names and profile links are supplied by the publisher. Review and publish these fields with the knowledge release.

Add the exact official hostname under Domain verification. The owner receives a random TXT challenge at `_unsite.HOSTNAME` with the value `unsite=SPACE_UUID.CHALLENGE`. The worker checks the actual DNS response, checks it daily and grants proof for seven days. Missing proof and failed rechecks remove the public assertion; expiration is also checked during public reads. Revoking and reclaiming a domain rotates its challenge.

Verification means control of a domain. It does not independently verify the identity of a legal person, the truth of all statements, or every external profile. Public `/authority` explains the scope. Domain proof never accepts a browser-supplied success flag.

Link the Unsite from the entity's official About or Resources page:

```html
<a rel="me" href="https://unsite.vercel.app/p/SPACE_UUID">Official knowledge and resources</a>
```

Use the same entity name and canonical URLs in the official site's Organization/Person structured data where accurate. No special AI file or structured-data label guarantees discovery or citation.

## Source maintenance and evidence

Visibility → Source updates supports Off, Daily, Weekly and Check now for active web-page sources. Checks respect the existing crawler's public-network validation, robots policy, response limits and redirect checks. Failed fetches back off and preserve the last saved version. Turning monitoring off clears its lease. A manual check while scheduling is off checks once.

Normalized text changes create a new private immutable source version and record the approved entries that depended on the source. Whitespace-only changes do not create versions or call AI. A concurrent manual version prevents the older network result from becoming a newer version. New versions require fresh AI authorization; no standing provider authorization is assumed and nothing is automatically published.

New preparation started from the UI uses the collection engine for either one source or several: source reading → bounded comparison planning → curation → semantic evidence verification → owner review. Consent explicitly covers source text, the goal, suggestions and relevant approved knowledge. The earlier single-source API remains for compatibility; its proposals do not receive the collection verifier's endorsement. A matching quote and even a semantic-support verdict do not establish independent real-world truth.

Comparison planning uses content and source dependencies as well as titles and aliases. It can include more than four existing records. When the 55,000-character comparison budget omits potentially related entries, proposals are explicitly flagged for review. Source-to-record dependencies remain private and never become fresh evidence merely because an earlier owner approved them.

Current limits remain visible: 8 source versions and 80 passages per collection run, 200 approved comparison records / 1.2 MB frozen knowledge, 1–200 requests per run, 50 requests per workspace per rolling day and 200 across the service. These are request caps, not dollar caps. Uncertain paid requests pause for explicit retry. Maintenance, source reading and collection processing use separate lanes. One invocation drains up to three collection steps.

## Retrieval and release checks

Public records are indexed once per immutable release using Postgres full-text search. Search supports English stemming and a small explicit synonym dictionary, then selects qualified excerpts while preserving complete record links. The default remains lexical retrieval. Optional semantic indexing and hybrid queries are implemented below; availability requires configuration, owner authorization and a complete current-release index. Real-model and multilingual evaluation remain launch tasks.

Record reads and search avoid downloading the complete release from the database. Full bundles remain available intentionally. Historical snapshots cannot be fetched publicly after rollback or unpublish. `release=UUID` fences multi-request reads; a different active release returns 409. ETag/If-None-Match supports conditional requests, with active publication access checked before 304. The public API applies a shared limit of 3,000 reads per publication per minute and returns 429 with Retry-After. This is an initial cost bound, not a comprehensive per-client abuse system.

Publishing or restoring a release queues an HTTP/MCP delivery check using already-public records only. The owner can rerun it in Visibility. Saved private retrieval questions are checked entirely inside Postgres against the release index; no HTTP URL or model receives those questions. These index regressions test the database ranking, not the public excerpt scorer or a live AI answer. Their results stay tied to the release and appear separately from HTTP/MCP checks. An earlier design that would have sent private questions through public API query strings was rejected by automatic approval review and replaced with this database-only design.

Run the same public HTTP/MCP contract check from another machine:

```bash
npm ci
node scripts/check-publication.mjs https://PROJECT.supabase.co/functions/v1/unsite/v2/SPACE_UUID RELEASE_UUID
```

The script does not call an AI provider. It checks published identity, the record directory, API schema, approved resources, one complete record and MCP fetch. It does not certify external resource uptime, entity truth or search ranking.

## Measure external visibility

Visibility → Observations records the exact question, platform/model, date, discovery mode, cited URLs, preferred-source assessment, answer accuracy, outdated-answer assessment, notes and response evidence. Citation totals count this publication's URLs, not any arbitrary citation. A supplied URL or configured MCP connection is separate from independent web discovery. Unknown assessments remain unknown. Export observations or the owner's full workspace export to compare over time.

Build a small benchmark for each real entity before drawing conclusions:

1. Basic identity and disambiguation: who/what it is and similarly named alternatives.
2. Offerings, capabilities, locations and contact resources that have actually been published.
3. Specific supported numbers, limits, conditions and exceptions.
4. A recently corrected fact or changed policy, with its effective date.
5. A question the publication does not answer, to check unsupported claims.
6. A resource-use question, such as where to obtain the official specification or media kit.

Run each question through independent web search in the selected AI products, direct URL access, and a configured MCP client separately. Record model/version, time, any location or account conditions, all citations and a response link or permitted excerpt. Repeat after substantive releases and on a consistent schedule. No baseline has been measured until real observations are recorded.

## Search indexing and custom domains

Submit the canonical sitemap through Google Search Console and Bing Webmaster Tools after verifying control of the application hostname or chosen custom domain. Bing AI Performance can provide citation observations where available. IndexNow requires proof/control of the submitted hostname and a corresponding key; do not submit URLs under a hostname the operator does not control.

Search crawling, user-initiated fetching and model-training crawling are different. The current robots policy exposes public knowledge and excludes private application routes. If the operator chooses a training restriction, configure GPTBot independently from OAI-SearchBot; do not block search by assuming they are the same crawler. Robots instructions are not access control; authentication and RLS protect private data.

Custom-domain activation remains an external setup task. Domain verification in Visibility proves control; it does not attach that hostname to Vercel or replace an existing official website. The implemented tenant routing serves one workspace per custom hostname. Configure hosting/DNS/TLS and verify its HTTPS connection before it becomes canonical. `UNSITE_PUBLIC_ORIGIN` remains the shared application fallback; do not change it for an individual tenant. Arbitrary DNS-verified domains are not functioning publication URLs until the connection check passes.

## Deployment and configuration

The canonical source generates the Vercel project with `scripts/prepare-vercel.mjs`. The generated repository includes the complete Edge Functions, shared code, tests, operational docs and the target's ordered applied migrations. Original development-project migration history is kept outside the CLI migration directory. Never replay both histories.

Apply database migrations first, deploy the public `unsite` Edge Function second, deploy `unsite-worker` third, and deploy the frontend last. Public `unsite` keeps `verify_jwt=false` because public reads are intentional and legacy publishing checks its own key. `unsite-worker` keeps gateway JWT verification and its separate scoped worker key. Never put service-role, worker, provider or database credentials into browser code or public configuration.

The Vercel build includes the target project's public Supabase URL and modern publishable key as deployment defaults. These are not administrative credentials; real sessions, RLS and guarded commands are still required. Explicit environment variables override them. An override to another project URL does not fall back to the default project's key. This resolves the previous Preview error caused by missing public connection settings.

The private worker token and gateway configuration remain environment settings for immediate job dispatch and model readiness reporting. The existing database cron can process maintenance without exposing those credentials to the frontend. Before enabling model preparation, configure the provider key and model in the worker, connect the frontend's private worker status/dispatch settings, and verify the configured model and budgets with a small approved example. Keep customer email callbacks on an allowed, configured application origin.

## Remaining real-world launch work

- Configure and verify the AI provider and optional semantic indexing after reviewing its separate scope, cost and consent.
- Supply real entity content, official URLs, DNS proof and approved public resource URLs.
- Complete a real owner-reviewed preparation, publication and correction walkthrough.
- Select and activate any custom hostname using the implemented routing and verification controls.
- Complete Search Console/Bing setup on an owned hostname and measure actual external citations over time.

## References

- [Google AI features](https://developers.google.com/search/docs/appearance/ai-features)
- [OpenAI crawlers](https://developers.openai.com/api/docs/bots)
- [OpenAI MCP integration](https://developers.openai.com/api/docs/mcp)
- [Bing AI Performance](https://blogs.bing.com/webmaster/February-2026/Introducing-AI-Performance-in-Bing-Webmaster-Tools-Public-Preview)
# GEO launch services — second implementation pass

The Visibility workspace now includes **Readiness** and **Search & domains**. All editing uses the existing right-side panels. Three launch tasks remain outside simulated/contract validation: real account/provider/domain configuration, an approved content walkthrough, and external citation trials. No customer domain or content is selected by the implementation.

## Semantic retrieval

The owner first enables semantic retrieval and chooses a daily request limit (1–1,000; default 100). The current public release then requires its own `openai-public-embeddings-v1` authorization. Subsequent releases do not inherit indexing approval. Only immutable approved release text, fields and context are sent to OpenAI. Private sources, drafts and saved questions are excluded.

The fixed embedding contract is `text-embedding-3-small`, 512 dimensions. The indexer splits the entire approved record representation into overlapping passages of at most 2,000 Unicode characters, submits at most 16 passages per request, and rejects releases above two million input characters before any provider call. Each completed batch records provider token usage when returned. The API and worker both read `OPENAI_API_KEY` from Supabase function configuration. Keys never appear in the browser, source export or public response.

Embedding requests are not automatically retried. A failed or expired provider attempt becomes blocked; the owner must review the retry notice and authorize its unfinished passages. Completed passages are not replayed. Disabling semantic retrieval stops new work and prevents vector queries. Availability is scoped to the exact active release and requires all of its passages to be ready. Releasing new content, unpublishing, or disabling the setting prevents mixed-release retrieval.

Ordinary `GET /search?q=...` and the MCP `search` tool remain lexical and make no provider request. Semantic retrieval is explicit:

```http
POST /functions/v1/unsite/v2/SPACE_ID/search?release=RELEASE_ID
Content-Type: application/json

{"query":"Where should a courier enter?","provider_consent":"openai-query-embedding-v1","limit":8}
```

MCP offers a separate `semantic_search` tool with the same query-provider consent. The requester must authorize sending its query to OpenAI. Public profiles and OpenAPI report current hybrid availability; HTTP 409 means the index/provider is unavailable or the release changed. HTTP 429 means the daily semantic request budget was reached or availability changed during reservation. Failed provider requests count toward that daily bound. Lexical retrieval remains available.

Hybrid retrieval combines full-text and cosine-similarity results with reciprocal rank fusion (`k=60`). Tenant, release and type/kind/topic filters apply before ranking. Exact cosine ranking over the bounded release avoids approximate-neighbor post-filter recall loss. The initial cosine cutoff is 0.72 distance; it is a retrieval heuristic requiring real-content evaluation, not a factual-confidence score. Results retain the existing qualified excerpts, complete-record URLs, context, fields, relationships and release ID. No answer is generated by this endpoint.

## Custom hostnames

1. Verify the **exact intended hostname** under Visibility → Identity. A parent-domain claim does not silently authorize all subdomains.
2. Select it under Search & domains → Connect hostname. Each workspace has one canonical custom hostname; replacing it resets search verification settings and disconnects the prior mapping.
3. The operator adds this hostname to the existing Unsite Vercel project and applies the project-specific DNS record shown by Vercel. Do not copy a guessed CNAME or replace an existing main website unintentionally. A separate hostname such as `knowledge.example.com` can preserve the main website.
4. Run Check connection. The worker verifies the `/.well-known/unsite-host` response over HTTPS, using the workspace binding and random probe token. DNS proof alone does not mark hosting as connected.

Only a current DNS claim and a current HTTPS connection make the custom address canonical. Connection checks repeat daily and expire after seven days. Revocation/expiry is checked on public reads, without a positive routing cache. `Host` is matched exactly; caller-provided forwarded-host headers are ignored. Unknown hosts and private application routes on tenant hosts return 404. Cookie/Authorization headers are not forwarded into public API delivery.

Connected hosts expose `/`, `/records/RECORD_ID`, `/api/…`, `/llms.txt`, `/openapi.json`, `/index.md`, `/mcp`, `/robots.txt` and `/sitemap.xml`. The application-host pages continue to advertise the verified canonical address. The underlying API remains the same release-fenced Supabase service. After unpublishing, record/page/API access stops while the hostname's empty sitemap and IndexNow verification file remain available for removal notifications.

This implements routing and verification. Vercel domain attachment, DNS records and TLS issuance are real external setup steps; no successful connection is fabricated in the sample workspace.

## Resource checks and readiness

Publishing queues availability checks for approved resource links. The worker respects crawling rules, checks public DNS addresses, limits redirects/timeouts, uses HEAD with a bounded GET-range fallback where needed, and cancels response bodies. It preserves URL query parameters, records status/content type/final URL, and reports format differences as warnings. It neither executes linked tools nor stores linked file contents. Current-release resources are checked daily; owners/editors can request another check after the five-minute limit. Results from a superseded release cannot overwrite the current result.

Readiness shows individual checks for publisher identity, public release, current HTTP/MCP delivery, resource availability, monitoring freshness, semantic indexing, custom hosting and search submission. Pending, missing, expired and failed checks remain distinct. A resource check is a point-in-time observation, not a historical uptime percentage. No readiness state establishes search rank, model preference, or independent truth of publisher claims.

## Search consoles and IndexNow

Copy the **content value** from Google Search Console's or Bing Webmaster Tools' HTML verification tag into Search & domains. Unsite emits the tags on the connected canonical hostname. The user finishes account verification and submits `https://HOST/sitemap.xml` in those services.

IndexNow is off by default. Enabling it requires `indexnow-public-urls-v1` authorization for recurring delivery of canonical public page URLs and a hostname verification key to `https://api.indexnow.org/indexnow`. Participating engines may share submitted URLs. The random key is served as `https://HOST/KEY.txt`; it is an IndexNow proof file, not an application credential.

The worker verifies that file before submitting a bounded batch. Only this host's root and approved record URLs are included. New publication, restore and unpublish events queue the union of old/current record URLs, so removals are represented. Private questions, originals, source names, third-party resource URLs and internal application paths never enter this queue. Revoked ownership, disabled notifications or replaced hostname/key bindings invalidate queued work. Rate limits and transient failures use bounded backoff, with no more than four attempts per submission. HTTP 200 is displayed as received; 202 is validation pending. Neither means indexed or cited.

## Operational validation

`tests/geo-launch.sql` runs only rollback fixtures for tenant access, per-release provider authorization, lease expiry, vector-only hits, daily request quotas, hostname verification/expiry, resource leases, search-submission scope and unpublish removals. `tests/geo-launch.test.mjs` checks HTTP/MCP consent boundaries, provider failures, custom-host isolation, preserved resource URLs, crawling restrictions and IndexNow response semantics. These tests make no real model call or search submission.

Implementation references: [OpenAI embeddings](https://developers.openai.com/api/docs/guides/embeddings), [Supabase hybrid search](https://supabase.com/docs/guides/ai/hybrid-search), [Next.js Proxy](https://nextjs.org/docs/app/api-reference/file-conventions/proxy), [Vercel domain setup](https://vercel.com/docs/domains/working-with-domains/add-a-domain), [IndexNow protocol](https://www.indexnow.org/documentation.html).

---
