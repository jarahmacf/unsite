Current UI, access controls, database migration, verification and remaining launch checks: [UI completion](ui-completion.md). Use that record before the historical deployment notes below.

# Resume Unsite deployment

Continue the completed implementation and the verified Macfarlane backend. Do not create another Supabase or Sites project. The remaining work is production hosting, provider configuration and real account/processing validation.

## Saved source

- Collection implementation commit: `eb80d0843c17111f9adb01d5dd35065cabf5eeb4`.
- Branch: `main`; use its latest state, including the verified SQL coverage correction and this deployment record.
- Existing checkout: `/workspace/sites/port`.
- Sites project ID: `appgprj_6a9b2a4a3ba881919750802831b1b9a1`.
- Source remote: `https://git.chatgpt-team.site/c26fded0-77a6-43ef-a105-9de7c6b32370/appgprj_6a9b2a4a3ba881919750802831b1b9a1.git`.
- Existing live development app: `https://port-agent-websites.workspace-106208.chatgpt.site`.

Use the existing Sites project and its native repository credential workflow if a new checkout is needed. The production portal is now exported to the user-authorized public repository `https://github.com/jarahmacf/unsite`; its backend source and full history remain in this original repository. Keep the development app and original backend available until the replacement is ready; neither was redeployed in this continuation.

## GitHub portal import: completed

The user explicitly approved switching to the GitHub-to-Vercel import route, created `jarahmacf/unsite`, and then explicitly approved its public visibility. Do not request that approval again or block on making the repository private.

- GitHub repository: `jarahmacf/unsite`, ID `1358633981`, public, owned by the connected `jarahmacf` account with write/admin access.
- Production portal branch: `main`.
- Uploaded portal commit: `28dd97a36e1d14247352c703e8c14150ba3f3483`.
- Uploaded tree: `5967708ce1225e306edf450c696c288dc93ec3df`, 104 files. Independently computing the Git tree from the prepared local file contents produced this exact SHA. A GitHub comparison confirmed `main` is identical to the uploaded commit.
- Latest portal update: `f05f401552cdcb29d0ad1ebc9e88436a1ee27507`, tree `debb05d080112f6fd4bd3e44f23af72d100d542b`. The user connected Supabase to Vercel, so the server adapter now accepts the integration's standard Supabase URL and public-key names. Explicit `UNSITE_SUPABASE_*` overrides remain supported. The README and deployment manifest document the aliases. This update was pushed to `main` without force.
- GitHub confirmed `main` is identical to this update, the remote runtime adapter matches the validated local file, and Vercel reports success for this exact commit at `https://vercel.com/jarah-1573/unsite/6SmjMe3eGfaeAxF1DgnhcJq9pBPk`. This verifies the compatibility update deployed, not the app's saved runtime settings or live account flow.
- The updated production build passed, along with checks for all integration alias pairs, explicit override precedence and rejection of privileged-key fallbacks. Regenerating the runtime adapter and deployment manifest from `scripts/prepare-vercel.mjs` produced byte-identical files.
- The Next.js 16.2.6 webpack production build and TypeScript phase passed again. A comparison of 91 unmodified exported source files found no drift from the original checkpoint `3495c59e668b634a8dde7f4c52136f09c2d1f0a2`.
- `vercel.json` configures Next.js, `npm ci` and `npm run build` at the repository root. The GitHub README explains the five server variables and remaining backend/account validation.
- No credentials, environment files, dependency directories, build output or customer data were uploaded. The runtime adapter only adds aliases for public Supabase connection values; scoped worker credentials remain explicit server-only settings.

The user supplied their Vercel dashboard URL `https://vercel.com/jarah-1573` and corrected Team ID `team_eFyqEacf4bVkcuEMs7X7vdNS`. Both the slug and corrected exact ID returned `Failed to list projects`; `list_teams` returned an empty array. After the user connected Supabase to Vercel, listing projects still failed and fetching the known `unsite` project returned `403 Forbidden`. Do not ask for either identifier again.

GitHub now reports a successful Vercel check for the initial portal commit `28dd97a36e1d14247352c703e8c14150ba3f3483`, linking to `https://vercel.com/jarah-1573/unsite/58ZisoJyvMHT7juvvBp54Xb5PAy5`. This establishes that the repository import deployed successfully; the app's public hostname, current saved environment settings and real account flow are not yet verified. Do not ask the user to repeat the import.

The authorized GitHub-to-Vercel route is working. Continue secure configuration of the existing backend and actual application origin, including any redeployment needed after settings change. A successful build alone is not a production-ready app. The Browser skill's explicit plugin-failure boundary prevents agent Browser from being used to recover this failed Vercel connector; bootstrap documentation was read but no Vercel page was opened through Browser. The user can configure the remaining settings in their own dashboard. Normal runtime approvals still apply; authorization for this specific route and public source upload does not authorize unrelated routes or source processing.

## New backend: already created and verified

- Supabase organization: **Macfarlane Sandbox**, `dikgwohjqigogutqozol`.
- New project: **Unsite**, `taikoetkfginjymihxpf`, region `us-west-1`.
- Project URL: `https://taikoetkfginjymihxpf.supabase.co`.
- Creation quote: $0/month, obtained and confirmed through the native Supabase workflow before creation.
- Original development project: `xwqjunvwimkqtumhbyre`. It is also visible in Macfarlane Sandbox. It was inspected read-only and was not changed or copied.

The new target was verified empty before bootstrap. Its actual service-assigned migration history is:

| Version | Name |
| --- | --- |
| `20260905223442` | `unsite_initial_schema` |
| `20260905223726` | `unsite_collection_coverage_aliases` |
| `20260905223951` | `unsite_worker_schedule` |

Exact applied SQL and the original bootstrap source-hash manifest are saved under `supabase/deployments/taikoetkfginjymihxpf/`. Do not replay historical source-project migration IDs into this target. Do not apply the bootstrap or entire pending collection schema again.

All five rollback-only suites passed: production isolation, AI authorization, linked knowledge, universal knowledge and collection coordination. The first collection run exposed ambiguous `value` columns in the planning and curation coverage queries. The correction qualified the source-item columns, was applied as a separate migration, and the full collection suite then passed. The pending schema also contains the correction for future deployments.

Security advisors reported no errors or warnings. Their single informational notice concerns RLS without a policy on `unsite_worker_credentials`; this is deliberate. Both `anon` and `authenticated` lack SELECT privileges. Every public table has RLS. All synthetic accounts, spaces and collection fixtures rolled back.

The public `unsite` and private `unsite-worker` Edge Functions are active at version 1, with their complete local dependency graphs. The public function has its intended custom/public routing and gateway JWT verification disabled. The worker retains gateway JWT verification **enabled** plus its separate scoped credential.

A fresh scoped worker secret was generated in the new database. Only its SHA-256 hash is in `unsite_worker_credentials`. Vault contains `unsite_worker_key`, `unsite_worker_gateway` and `unsite_worker_url`. The gateway credential is the new project's legacy anon JWT, separate from the publishable key used by the portal. Never print or commit these values. The named minute schedule `unsite-process-sources` is active and checks individual jobs and collection runs.

Actual deployed HTTP checks passed: public health 200; worker without gateway authorization 401; gateway credential without scoped key 401; both credentials 200; a browser Origin 403. Authenticated worker health reports `model: false`, so provider setup is still missing. No paid provider request was made.

## Remaining blocks

The previous `-32001: Unknown tool` routing error is resolved. Vercel documentation search works, but project access failed even with the user-supplied workspace slug and exact Team ID above; the current specific-project lookup reports `403 Forbidden`. Vercel is installed and enabled. Do not repeatedly request reconnection, more IDs, or a replacement account. GitHub confirms a successful Vercel deployment of the imported portal; secure runtime configuration and verification remain outstanding.

Fresh Supabase checks match all three migration versions above and both active version-1 Edge Functions, including their JWT settings. All three named worker Vault secrets are present. A GET to the exact new-project worker endpoint, authenticated inside Supabase with the existing Vault credentials, returned HTTP 200 with `{"worker":true,"model":false,"modelName":"gpt-5-mini-2025-08-07","consentRequired":true}`. Credentials were not printed or exported. No model request or source processing was triggered, and the prior SQL suites were not rerun.

Supabase native tools work in this session; the previous `Unknown tool` routing error is resolved. There is no authenticated Supabase CLI or local management token. An attempted CLI package download was cancelled by network approval, so migrations used the native API and retained its actual versions.

Earlier Vercel state: the native `deploy_to_vercel` action was rejected by automatic approval review because it considered source/configuration disclosure to an unverified Vercel destination insufficiently authorized. The user subsequently identified their Macfarlane-email account and explicitly approved the GitHub-to-Vercel import route recorded above, including public source upload. Preserve this updated authorization. Do not substitute unrelated routes or evade runtime approval results. The later successful GitHub Vercel check is recorded above.

The generated portal source still exists at `/workspace/scratch/80c9790481f2/unsite-deployment/vercel`, now with successful `.next` build output. Its dependencies are a local symlink to the existing Sites checkout's installed dependencies, excluded from the upload. The durable portal source is now the verified GitHub commit above; use that repository for the import rather than regenerating or reimplementing it. Local upload staging at `/workspace/scratch/eadab5cba095/unsite-import-staging` is disposable and contains no credentials.

`OPENAI_API_KEY` is absent. Configure it as a Supabase Edge Function secret through the user's secure settings, not in chat, Git or the portal. The current default model remains `gpt-5-mini-2025-08-07`; `UNSITE_MODEL` can override it. No real model-quality evaluation has run.

## Continue in this order

1. Continue configuring the imported `unsite` Vercel project in workspace `jarah-1573`, Team ID `team_eFyqEacf4bVkcuEMs7X7vdNS`. GitHub confirms successful deployments of both the initial import and the compatibility update. Inspect the actual application origin and current settings where access permits. Do not repeat the import.
2. Configure `OPENAI_API_KEY` securely on the new Supabase project and confirm authenticated worker health reports a configured model. This alone does not authorize processing private material.
3. The Supabase integration can now supply the URL and public key through `SUPABASE_URL` / `NEXT_PUBLIC_SUPABASE_URL` and `SUPABASE_PUBLISHABLE_KEY` / `NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY` (legacy anon names also work). Explicit `UNSITE_SUPABASE_URL` and `UNSITE_SUPABASE_PUBLISHABLE_KEY` take precedence. Verify the integration points to `taikoetkfginjymihxpf`. Configure the remaining `UNSITE_APP_ORIGIN`, `UNSITE_WORKER_TOKEN` and `UNSITE_WORKER_GATEWAY_KEY` using this project's actual origin and existing Vault-backed credentials. The integration does not synchronize the custom Vault secrets; never copy credentials from the original project.
4. Deploy the verified generated target to the approved Vercel destination. Configure Supabase Auth site URL, redirect allowlist and production email delivery for the actual application origin. These settings and email delivery have not been configured or verified for the replacement portal.
5. Validate real signup, confirmation, sign-in, recovery and sign-out. Perform a deliberately approved small mixed-source run, inspect actual provider usage, evidence and owner review, and verify published-only API/MCP/Markdown/JSON delivery. Real account/email and model-quality flows remain untested.

Unsite supports mixed subject matter while preserving evidence, attribution, framing, qualifications and unknowns. Models cannot publish, email or deliver files. Owner review and explicit immutable publication remain mandatory. Read `docs/collection-coordination.md` and `docs/fresh-deployment.md` for exact limits and remaining launch work.
