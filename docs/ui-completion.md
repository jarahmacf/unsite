# Unsite workspace completion — 7 September 2026

This record supersedes earlier UI and deployment TODOs for the current preview. The original Sites project, GitHub repository, Vercel project and Supabase databases are retained.

## Interface

- Zinc, black and white surfaces, understated borders, compact controls, and the established Untitled UI layout compositions. The existing local Radix/shadcn primitives remain in place; no second component framework or paid Untitled component code was imported.
- Outfit headings remain at 550. Geist is used for body text and controls; Geist Mono is reserved for technical addresses and identifiers.
- Streamline Plump Solid Free SVGs are self-hosted in the application. Utility crops/rotations and licensing are recorded in `public/icons/NOTICE.md`; visible attribution appears in the sidebar.
- Add, edit, invite, review, publish, restore, and confirmation flows open from the right. Panels retain focus trapping, Escape handling, focus restoration, scroll containment, mobile sizing and reduced-motion behavior. Unsaved forms have inline discard confirmation.
- All seven workspace sections are implemented. Settings now includes General, People & access, Activity, Your account and Connections. First-workspace onboarding, empty states, connection failures, route errors and missing pages are covered.
- Section URLs support refresh and browser back/forward through `?tab=…`. Existing preview access parameters are preserved.

## Connected non-AI flows

- Knowledge search, content type and publication inclusion filters query the complete database collection. Knowledge and review have independent pagination; polling no longer resets a loaded review page.
- Private source import and version history remain intact. Archived sources can be restored without dispatching processing or modifying original versions.
- Owners create seven-day invitation links for a specific confirmed email, choose editor/viewer access, revoke invitations, update roles and remove members. Recipients explicitly accept while signed in. The invitation link must be shared by its creator; this feature does not send email.
- Invitation tokens are generated with 32 random bytes. Only SHA-256 hashes are stored. The table is denied to customer roles; guarded functions expose only scoped metadata. Accepted invitations cannot restore membership after removal. Owners cannot remove/demote themselves or leave an ownerless workspace.
- Account settings support current-password verification before changing a password and signing out other sessions. Supabase access tokens remain valid until expiry after session revocation.
- Owners can export workspace records, source text, relationships, review history and release snapshots. Credentials and private storage paths are excluded. Original binary files remain individually downloadable in Sources.
- Publishing retains explicit owner approval, exact draft revision checks, immutable snapshots, export, history viewing, restoration and unpublishing. A hosted address is available; the unfinished custom-domain placeholder has been removed from this UI.
- The sign-in-free `/demo` uses only local sample operations, including access settings and exports. It cannot call authentication, storage uploads, AI preparation, live invitations or live publishing.

## Database deployment

The additive migration was applied to `taikoetkfginjymihxpf` as **20260907034412_unsite_workspace_controls**. Its source CLI migration is `20260907032348_workspace_controls.sql`; the exact applied copy is under this project's deployment directory. Do not replay the bootstrap or mix the original development database's migration history into this project.

New public RPCs: `unsite_workspace_settings`, `unsite_workspace_command`, `unsite_record_directory`, `unsite_workspace_export`. Public wrappers use SECURITY INVOKER. Privileged work remains in `unsite_private` with explicit membership and role checks.

The rollback-only `tests/workspace-controls.sql` passed against the live schema: owner/editor/viewer behavior, cross-tenant denial, invitation hash privacy, email confirmation, token mismatch, expiration, revocation, removal, owner immutability, source restoration, search beyond 200 records and complete owner export. Synthetic users, records and queued work were rolled back.

Security advisors reported no warnings or errors. The two informational [RLS-without-policy notices](https://supabase.com/docs/guides/database/database-linter?lint=0008_rls_enabled_no_policy) concern `unsite_worker_credentials` and `unsite_invitations`. Both are intentionally denied to direct customer access, with RLS enabled and all customer table grants revoked.

## Verification and remaining launch work

- 46 Node tests passed, including API session/origin guards, invitation contracts, demo network isolation, retrieval, releases, and existing mocked AI/collection regressions.
- TypeScript and the canonical Sites/Vinext production build passed. The generated Next.js production build and its TypeScript phase also passed before updating the preview branch.
- Browser interaction/accessibility checks were not performed in this session. The applicable Sites workflow requires an explicit browser-testing request.
- The OpenAI key and real-content preparation run remain intentionally deferred. No model request or paid content processing was made in this UI pass.
- Production signup/confirmation/recovery email delivery still needs a real-account check and, if required, SMTP configuration. Verify Auth redirect allowlists for the actual application origin, including confirmation callbacks carrying invitation return paths. These require external account/email configuration and must not be described as already validated.
- Custom domains, billing, social scanning, OCR/media adapters and outbound delivery are optional product expansions, not completed features of this release.

The UI preview branch remains `ui/foundation-and-sources` in `jarahmacf/unsite`, in draft PR #1. A preview is not a promotion of the production `main` branch.
