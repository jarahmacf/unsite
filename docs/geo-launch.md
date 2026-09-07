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

Public records are indexed once per immutable release using Postgres full-text search. Search supports English stemming and a small explicit synonym dictionary, then selects qualified excerpts while preserving complete record links. This is lexical retrieval. Semantic embeddings and multilingual semantic evaluation are not enabled and must not be described as active AI search.

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

Custom-domain activation remains an external setup task. Domain verification in Visibility proves control; it does not attach that hostname to Vercel or replace an existing official website. Before activation, choose the intended hostname, configure hosting/DNS/TLS, decide whether it serves one entity or the whole app, and update `UNSITE_PUBLIC_ORIGIN` consistently in the frontend and public Edge Function. Per-tenant custom-host routing is not implemented in this release. Do not advertise arbitrary verified domains as functioning publication URLs.

## Deployment and configuration

The canonical source generates the Vercel project with `scripts/prepare-vercel.mjs`. The generated repository includes the complete Edge Functions, shared code, tests, operational docs and the target's ordered applied migrations. Original development-project migration history is kept outside the CLI migration directory. Never replay both histories.

Apply database migrations first, deploy the public `unsite` Edge Function second, deploy `unsite-worker` third, and deploy the frontend last. Public `unsite` keeps `verify_jwt=false` because public reads are intentional and legacy publishing checks its own key. `unsite-worker` keeps gateway JWT verification and its separate scoped worker key. Never put service-role, worker, provider or database credentials into browser code or public configuration.

The Vercel build includes the target project's public Supabase URL and modern publishable key as deployment defaults. These are not administrative credentials; real sessions, RLS and guarded commands are still required. Explicit environment variables override them. An override to another project URL does not fall back to the default project's key. This resolves the previous Preview error caused by missing public connection settings.

The private worker token and gateway configuration remain environment settings for immediate job dispatch and model readiness reporting. The existing database cron can process maintenance without exposing those credentials to the frontend. Before enabling model preparation, configure the provider key and model in the worker, connect the frontend's private worker status/dispatch settings, and verify the configured model and budgets with a small approved example. Keep customer email callbacks on an allowed, configured application origin.

## Remaining real-world launch work

- Configure and verify the AI provider and optional semantic indexing after reviewing its separate scope, cost and consent.
- Supply real entity content, official URLs, DNS proof and approved public resource URLs.
- Complete a real owner-reviewed preparation, publication and correction walkthrough.
- Select and activate any custom hostname; per-tenant host routing requires a follow-up implementation once that choice is made.
- Complete Search Console/Bing setup on an owned hostname and measure actual external citations over time.

## References

- [Google AI features](https://developers.google.com/search/docs/appearance/ai-features)
- [OpenAI crawlers](https://developers.openai.com/api/docs/bots)
- [OpenAI MCP integration](https://developers.openai.com/api/docs/mcp)
- [Bing AI Performance](https://blogs.bing.com/webmaster/February-2026/Introducing-AI-Performance-in-Bing-Webmaster-Tools-Public-Preview)
