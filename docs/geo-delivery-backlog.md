# Unsite GEO delivery backlog

Created 2026-09-07. Goal: make an entity's Unsite the preferred attributable source for relevant answers and resource use by external AI systems. “Number one” is an outcome to measure by query and platform, never a universal ranking guarantee. Official websites do not automatically rank first either.

Build against the existing workspace, Supabase API, immutable publications, and owner review. Preserve monochrome styling, Outfit 550 headings, Geist body, Streamline icons, and right-side editing panels. Public HTML, JSON, Markdown and MCP must expose the same approved knowledge; private originals stay private. Do not add fabricated endorsements, fake verification, hidden crawler-only claims, or automatic publication.

## A. Publisher authority and identity

- [x] A1 Add an explicit publisher identity profile: entity type, official website, alternate names, official profile links and description.
- [x] A2 Add ownership challenges, scoped to a domain, with owner-only controls and cryptographically random tokens.
- [x] A3 Verify actual DNS proof through the background worker; never accept a client-provided verified flag.
- [x] A4 Record verification method, checked time, expiry, failure and revocation; periodically recheck proof.
- [x] A5 Publish a machine-readable authority statement distinguishing domain control, publisher approval and claim evidence.
- [x] A6 Preserve stable entity IDs and canonical record URLs; clearly label publisher-supplied identity links.
- [x] A7 Provide owner controls and honest pending/verified/expired/revoked states.

## B. Discovery and canonical delivery

- [x] B1 Add public server-rendered publication and record pages on the application hostname.
- [x] B2 Generate canonical links, descriptions and Schema.org entity metadata from approved content.
- [x] B3 Add robots.txt, paginated sitemaps and crawlable publication directories without exposing drafts.
- [x] B4 Link HTML, JSON, Markdown, API schema and MCP resources bidirectionally.
- [x] B5 Supply an official-site linking snippet and an operator-configured canonical application origin.
- [x] B6 Document separate search and training crawler controls; do not claim llms.txt guarantees discovery.
- [x] B7 Make unpublish, rollback, source changes and verification revocation consistent across every representation.
- [ ] B8 Implement per-tenant custom-host routing after the customer selects the intended hostname and hosting arrangement. DNS/TLS activation also requires that external setup.

## C. Useful public resources and API

- [x] C1 Add an owner-approved catalog of resources with title, description, URL, format and version/date information.
- [x] C2 Expose resource discovery and retrieval through HTTP, MCP, Markdown and public pages.
- [x] C3 Expose available capabilities honestly; search/read/download links must resolve, unsupported transactional actions must not be advertised.
- [x] C4 Add conditional requests and release-aware validators while preserving immediate unpublish access checks.
- [x] C5 Avoid loading the entire release for ordinary record reads and indexed search.
- [x] C6 Add bounded public read quotas and useful retry/error responses.
- [x] C7 Publish API examples and a reproducible external-client contract check.

## D. Retrieval and knowledge organization

- [x] D1 Fix morphological and synonymous query failures with an explicit, tested retrieval strategy.
- [x] D2 Index approved release records in Postgres with stable record/release identifiers.
- [x] D3 Retain full text, structured fields, framing, attribution, dates and linked records in retrieval results.
- [x] D4 Route update comparisons using provenance and content, not only titles/aliases/topics.
- [x] D5 Remove the arbitrary four-comparison blind spot while bounding task inputs.
- [ ] D6 Add optional semantic indexing/query support with truthful availability and provider consent; validate with real models when configured.
- [x] D7 Add regression cases for paraphrases, numbers, conflicting versions, absent answers and renamed entities.

## E. Recurring monitoring and incremental updates

- [x] E1 Add per-source monitoring controls: off, daily or weekly, plus check now.
- [x] E2 Persist due time, last check, last content change, failure status, retry time and worker lease.
- [x] E3 Respect crawl permissions and public-network boundaries on every refresh.
- [x] E4 Compare normalized content hashes and skip unchanged sources without an AI call.
- [x] E5 Create immutable new versions only for changed content; identify affected accepted records.
- [x] E6 Preserve owner edits, expose review-needed/stale indicators and explain source changes.
- [x] E7 Keep model authorization explicit for every new version. Standing authorization is not enabled; any future implementation requires its own reviewed scope and budget.
- [x] E8 Improve queue fairness, bounded throughput and automatic recovery for deterministic work.
- [x] E9 Make request and size limits coherent and visible; never silently replay an uncertain paid request.

## F. Evidence and publication quality

- [x] F1 Route new UI preparations for one or several sources through the same semantic-verification pipeline. Keep earlier API proposals explicitly unverified.
- [x] F2 Keep quote-existence checks separate from evidence-support verdicts and real-world truth.
- [x] F3 Preserve source-to-record dependencies and evidence history through updates.
- [x] F4 Surface conflicts, removed evidence and incomplete coverage for owner review.
- [x] F5 Expose approved provenance and effective dates without leaking private source names, URLs or files.
- [x] F6 Rerun saved questions inside the release's Postgres index and store the results per release. Keep private questions out of public URLs and external delivery tasks.

## G. GEO measurement and service health

- [x] G1 Add a visibility workspace with explicit query/platform/date observations and cited URLs.
- [x] G2 Measure citation inclusion, preferred-source use, answer correctness and stale-answer incidence separately.
- [x] G3 Separate observed external citations from internal tests and inferred crawler traffic.
- [ ] G4 Add readiness checks for identity, discovery, resource integrity, retrieval and freshness; never label a readiness score as search rank.
- [x] G5 Record and surface failed monitoring, processing and public-delivery checks.
- [x] G6 Provide a repeatable benchmark for web-search discovery, direct HTTP and connected MCP clients.
- [x] G7 Support exports of observations, delivery results and owner workspace evidence for comparison over time.
- [ ] G8 Document search-console/IndexNow integration and activate only for a domain the customer controls.

## H. Delivery, validation and launch

- [x] H1 Export the entire backend, ordered applied migrations, API tests and operational docs to the GitHub delivery repository.
- [x] H2 Document and validate frontend/backend compatibility and deployment order.
- [x] H3 Add regression tests for tenant isolation, ownership proof, version fencing, refresh idempotency and public projection.
- [x] H4 Validate TypeScript, the existing builds, API contracts and database behavior.
- [x] H5 Save source and publish the authorized application preview and backend updates.
- [ ] H6 Complete external setup: provider credentials, Vercel runtime configuration, official domain proof and custom-domain hosting where selected.
- [ ] H7 Run a small explicitly approved real-content preparation and publication walkthrough.
- [ ] H8 Run external-agent discovery/citation trials and record the baseline; ranking improvements require observations over time.

## Acceptance criteria

An external consumer can discover the canonical publication, identify its publisher and the exact scope of verification, retrieve complete approved knowledge/resources, cite stable URLs, distinguish evidence and freshness, and observe corrections without seeing drafts. Owners can maintain that publication from the existing workspace. An unknown or unverified result is displayed honestly. A passing internal test or a successful HTTP read is never reported as an external model citation.

## References

- [Google: AI features and your website](https://developers.google.com/search/docs/appearance/ai-features): ordinary crawl/index/content requirements still matter; inclusion is not guaranteed.
- [OpenAI crawler documentation](https://developers.openai.com/api/docs/bots): search crawling and training controls are separate.
- [OpenAI MCP documentation](https://developers.openai.com/api/docs/mcp): a connected tool interface is distinct from ordinary web discovery.
- [Bing AI Performance](https://blogs.bing.com/webmaster/February-2026/Introducing-AI-Performance-in-Bing-Webmaster-Tools-Public-Preview): citation visibility is measurable but is not a universal ranking position.

Implementation checked above is covered by the TypeScript/build gates, targeted API tests or database regression checks. Current validation: 57 canonical tests; the generated Next.js app builds successfully and its production test selection passes. Four GEO migrations are applied to the target project; both Edge Functions are ACTIVE at version 2. The GEO preview deployment is READY. Its account endpoint, public directory, sitemap, robots file and demo return HTTP 200; the directory correctly shows no publications yet. Runtime and browser interaction checks with a real customer account/content remain part of launch validation.

Remaining implementation: optional semantic indexing (D6), per-tenant custom hosts (B8), a broader readiness/resource-uptime system (G4), and ownership-dependent search-console/IndexNow activation (G8). These are not represented as completed features. Source monitoring and HTTP/MCP checks do not establish external AI citation performance.

 Account-owned configuration, actual DNS proof and external ranking observations cannot be fabricated as completed implementation.
