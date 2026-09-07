Current UI and database completion record: [UI completion](ui-completion.md). Earlier outstanding-work paragraphs below are historical.

# Fresh Unsite deployment

The repository contains the database schema, worker and public API source, private portal, tests and deployment inputs. No customer data or service credentials are included in the bootstrap. The existing development app is hosted through Sites; a new Supabase project or a Vercel connection does not move it automatically.

The selected Macfarlane destination is now initialized as `taikoetkfginjymihxpf`. Do not bootstrap it again. Its three actual migrations, passing SQL suites, active backend functions and outstanding hosting/provider setup are recorded in [the current handoff](resume-unsite.md) and `supabase/deployments/taikoetkfginjymihxpf/`. The following preparation procedure remains for genuinely empty targets.

## Prepare the database

First verify the connected Supabase organization and intended project. Creating a project requires selecting the organization, checking its actual creation/hosting cost, and confirming that cost through the service's normal flow. Do not assume that a newly connected workspace is the original deployment target.

To prepare a reviewable schema for an empty project, run:

```sh
node scripts/prepare-supabase-bootstrap.mjs /absolute/output/directory
```

This writes unsite-bootstrap.sql and a source-hash manifest, and makes no network calls. It combines the recorded historical schema with the pending collection update. It rejects a database that already contains Unsite tables. The older prototype tables are included because the current public worker still supports that API version. The bootstrap does not create accounts, copy originals or releases, configure secrets, or transfer source-project data.

Apply this as an initial migration to an empty managed Supabase project only. Record the actual service-assigned initial migration version and bootstrap manifest for the new project; do not claim the old project's migration IDs were applied there. Existing projects instead apply only their missing migrations. Keep project histories separate if both deployments are retained.

After application, run the rollback-only suites in tests/production-isolation.sql, tests/ai-authorization.sql, tests/linked-knowledge.sql, tests/universal-knowledge.sql and tests/collection-coordination.sql. Check the service's security advisors and confirm that customer data is member-readable only, that client writes go through guarded commands, and that service-only dispatch functions are not callable by customers.

## Configure processing and public delivery

Deploy supabase/functions/unsite-worker with JWT verification enabled and its complete local dependency graph. Deploy supabase/functions/unsite with JWT verification disabled for its intentionally public read endpoints; its private commands retain their own credential checks.

Generate a new scoped worker invocation secret. Store only its SHA-256 hash in unsite_worker_credentials. Configure the raw invocation secret in the portal and Supabase Vault, never in repository files. Configure a gateway credential accepted by the project's JWT gateway separately. Vault names are unsite_worker_key, unsite_worker_gateway and unsite_worker_url; the last points to the new project's worker endpoint.

Configure OPENAI_API_KEY as a Supabase function secret. UNSITE_MODEL optionally overrides the pinned default model. The portal must never receive the provider or database service secret. Run supabase/worker-schedule.sql after Vault is configured; it installs the named minute schedule for both source jobs and collection runs. Check authenticated worker health, then perform one deliberately approved small mixed-source run and inspect its actual provider usage, evidence and owner review behavior.

## Connect the application

Configure the portal's server runtime values for the selected project:

| Variable | Meaning |
| --- | --- |
| UNSITE_SUPABASE_URL | New project API origin |
| UNSITE_SUPABASE_PUBLISHABLE_KEY | New project's publishable client key |
| UNSITE_APP_ORIGIN | Actual application origin |
| UNSITE_WORKER_TOKEN | New scoped worker invocation secret |
| UNSITE_WORKER_GATEWAY_KEY | New project gateway credential |

The generated Vercel portal also accepts the Supabase integration's `SUPABASE_URL` / `NEXT_PUBLIC_SUPABASE_URL` and `SUPABASE_PUBLISHABLE_KEY` / `NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY` (or legacy `SUPABASE_ANON_KEY` / `NEXT_PUBLIC_SUPABASE_ANON_KEY`). Explicit `UNSITE_SUPABASE_*` settings take precedence. Secret/service-role keys are never aliases. The integration must point to the existing Unsite project, `taikoetkfginjymihxpf`. It does not supply the custom application origin, scoped worker credentials or OpenAI function secret.

Auth site URL, allowed redirects and production email delivery must match the actual application host. Test signup, email confirmation, sign-in, recovery and sign-out with real accounts before opening customer access. The public API base is derived from the configured project URL.

For the current Sites app, update its server environment and deploy the built private version only after the backend passes.

For Vercel, the production Next.js build is now prepared reproducibly:

```sh
node scripts/prepare-vercel.mjs /absolute/new/output/directory
```

The generator copies the production workspace, account and API routes, shared UI and knowledge logic, and the existing dependency lockfile. It replaces the Cloudflare environment binding in the generated project with an explicit server-only process environment adapter, sets account/API handlers to dynamic responses, and supplies a Next.js production build configuration. Retained D1 prototype and legacy routes are excluded from this target. The original Sites source and dependency manifests are preserved. No credentials, hosting metadata or customer data are copied.

The user approved the GitHub import and public source visibility. The initial 104-file portal import was verified against its locally computed Git tree, and GitHub now reports a successful Vercel deployment of that import in project `unsite`, workspace `jarah-1573`, Team ID `team_eFyqEacf4bVkcuEMs7X7vdNS`. After the user connected Supabase to Vercel, commit `f05f401552cdcb29d0ad1ebc9e88436a1ee27507` added standard integration environment aliases and updated the README and manifest on `main` in `https://github.com/jarahmacf/unsite`. The updated Next.js 16.2.6 webpack build and TypeScript phase passed, and generated deployment files match the export generator. Direct Vercel project access still returns `403 Forbidden`, so the public hostname and saved settings remain unverified. No runtime secrets or customer data were uploaded. The remaining custom server settings, production Auth/email configuration and real account/processing validation are still required. See the current handoff for exact results and preserve the updated route authorization.

Customer custom domains, social account connections, OCR/media adapters, durable heavy-processing infrastructure, billing and outbound delivery still require separate implementation. The collection coordinator is designed to admit additional source adapters without changing the owner review/publication boundary.
