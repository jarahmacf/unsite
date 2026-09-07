# UI foundation and Sources

The first UI slice applies a restrained Untitled UI direction through Unsite's existing accessible components. It does not introduce a second component framework or copy paid Untitled UI code.

## Included

- Outfit (550) headings, Geist body and controls, and occasional Geist Mono technical values. Latin variable fonts and their OFL notices are self-hosted in `public/fonts`.
- Neutral semantic tokens, shared buttons, form hints, status badges, dialogs, and readable evidence styles.
- A shared workspace shell with desktop navigation, an accessible mobile navigation sheet, breadcrumbs, account access, and a skip link.
- Sources with search, type filters, archive browsing, status explanations, private source details, and preserved version history.
- File, page, and text intake. File selection validates formats and sizes, supports removal, and preserves the existing signed upload, completion, and retry contracts.
- Optional AI consent is separate from saving sources. AI preparation is unavailable in the UI until the existing runtime reports a connected model.
- Overview, authentication, Knowledge, Review, publication, agent access, and Settings inherit the shared typography and neutral presentation. Their existing data and action contracts remain in place.

## Sign-in-free sample workspace

`/demo` opens every workspace section with synthetic content and no Unsite sign-in. It uses the actual Overview, Sources, Knowledge, Review, Agent access, Publish, and Settings views. It can add sources and versions, edit knowledge, review a suggestion, run local retrieval checks, change workspace details, and simulate immutable releases. File/page previews do not upload a file or fetch a page. Everything resets on reload or Reset demo.

The demo route is included in the production export and marked noindex. `/ui-preview` remains a development-only alias. An explicit API context and local gateway keep demo operations in memory; there is no live transport fallback. Authentication, model calls, real uploads, and unsupported operations are rejected. Simulated publications have no public API address. The real workspace and all server API authentication continue to use their existing guards. Vercel deployment protection is independent of Unsite sign-in; a protected preview needs a Vercel share link.

## Verification

- TypeScript check passed.
- Sites/Vinext build passed.
- Fresh generated Next.js/Vercel production build passed, including font assets, the shared components, and `/demo`; `/ui-preview` stays outside the production export.
- Fifteen targeted tests passed: the production contract suite and tests for sample isolation, version preservation, idempotent intake, source status, knowledge edits, revision conflicts, evidence review, retrieval, and simulated release history.
- Browser interaction, responsive rendering, and actual account/email delivery have not been tested in this pass.

## Next UI slice

Refine the Knowledge editor and evidence review with the same system. The demo already exercises their existing editing and review workflows. Real AI provider setup remains a separate integration step.
