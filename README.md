# Unsite

The production Next.js portal for Unsite: a workspace for preparing evidence-backed knowledge, owner review, and explicit publication.

This is the prepared Vercel portal exported from the existing Unsite implementation. The deployed Supabase database and Edge Functions remain the existing Macfarlane Unsite project. Do not create or bootstrap another database for this import.

## Deploy to Vercel

Import this repository into the `jarah-1573` Vercel workspace (`team_eFyqEacf4bVkcuEMs7X7vdNS`). Use the repository root and the included `vercel.json` settings:

- Framework: Next.js
- Install command: `npm ci`
- Build command: `npm run build`
- Output directory: framework default

Set these server environment variables in Vercel's secure project settings before treating the deployment as ready:

| Variable | Value source |
| --- | --- |
| `UNSITE_SUPABASE_URL` | `https://taikoetkfginjymihxpf.supabase.co` |
| `UNSITE_SUPABASE_PUBLISHABLE_KEY` | The existing Unsite project's modern publishable API key |
| `UNSITE_APP_ORIGIN` | The actual HTTPS application origin assigned in Vercel |
| `UNSITE_WORKER_TOKEN` | Existing Unsite Vault secret `unsite_worker_key` |
| `UNSITE_WORKER_GATEWAY_KEY` | Existing Unsite Vault secret `unsite_worker_gateway` |

Keep credentials in secure settings, outside repository files. The worker credentials must remain server-only; do not prefix their variable names with `NEXT_PUBLIC_`.

Configure `OPENAI_API_KEY` in Supabase Edge Function secrets, not Vercel or GitHub. The deployed worker last reported that this key was missing. Configuring the provider does not authorize processing source material.

After the actual application origin is established, configure Supabase Auth's site URL and redirect allowlist and production email delivery. Validate signup, confirmation, sign-in, recovery and sign-out, then run one explicitly approved processing sample and check provider usage and published delivery.

## Local development

Use `npm ci`, set the server variables in an untracked local environment file, and run `npm run dev`. `npm run build` performs the production build and its TypeScript phase; `npm run typecheck` runs TypeScript separately.

## Verification and source history

The production build and TypeScript phase passed again before this import. Real account/email and model-quality flows remain unverified, and the portal is not production-ready until its external settings and end-to-end checks are complete.

Source implementation checkpoint: `3495c59e668b634a8dde7f4c52136f09c2d1f0a2` in the existing Unsite Sites repository. `deployment-source.json` describes the exported paths and server-runtime adapter. Supabase source and deployment history remain in that original repository; this import contains the portal.

Published knowledge requires owner review and an explicit immutable release. Model processing cannot publish, send emails or deliver files on the owner's behalf.
