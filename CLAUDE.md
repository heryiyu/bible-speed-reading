# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

新生命聖經速讀計畫 (NewLife Bible Speed Reading) — a Traditional-Chinese PWA for a church's quarterly Bible-reading challenges: reading tracker, plans, personal/group statistics, leaderboards, gamification badges, and devotional notes. It is a **satellite app** of the NewLife Member Hub and integrates with the NLC (紟道) ecosystem SSO.

Stack: **vanilla JS, HTML, and CSS for all the main tabs — no framework, no bundler for app code in dev** (the production build runs a real `esbuild --bundle --minify` pipeline via `scripts/bundle.mjs`, not just hashing — see [Commands](#commands)). One deliberate exception: the issue-report feature (`components/issue-report/*.tsx`, mounted via React's `createRoot` from `js/modules/issue-report-ui.js`) is a real React + TypeScript island, bundled as its own separate lazy chunk (`issue-report-ui.bundle.js`) — "no framework" does not apply to that corner of the codebase. Third-party libs: Supabase JS loads from a CDN `<script>` in `index.html`; Chart.js and html2canvas are each lazy-loaded from CDN on demand by the module that needs them (`plan.js`, `home.js`) rather than declared upfront. Icons are **Lucide**, compiled at build time into `js/design/icon-registry.js` by `scripts/generate-icon-registry.mjs`. Backend is Supabase (Postgres + Edge Functions). Hosted on Vercel.

## Commands

```bash
npm run build             # generate-icon-registry.mjs → build-config.js → bundle.mjs — full pipeline, not just config.js
npm run dev                # npx serve . — also `npm start` (see caveat below, this does not fully work as-is)
npm test                    # vitest run — ~160 files / ~1,300 cases
npm run test:watch          # vitest, watch mode
npm run bump -- <label>     # scripts/bump-version.mjs — rewrites every ?v=YYYYMMDD_... string in js/app.js to one new version in one shot and syncs index.html, instead of hand-editing each tag
```

There is **no linter**, but there **is** a real, actively-maintained `vitest` suite (jsdom, plus a handful of React Testing Library component tests under `components/`/`lib/`/`tests/`) — run `npm test` before calling a change done. Don't rely on `node --check` as a substitute: it only validates syntax, so it will not catch e.g. a leftover reference to a variable whose declaration got deleted in a refactor (that class of bug has caused a production incident before — see `feedback_refactor_verify_runtime_not_just_syntax` in project memory).

`npm run build` is **not** just `config.js` regeneration — it runs three scripts in order: `scripts/generate-icon-registry.mjs` (compiles the Lucide icon manifest into `js/design/icon-registry.js`), `build-config.js` (regenerates `config.js` from `.env`), then `scripts/bundle.mjs` (runs `esbuild --bundle --minify --target=es2020` per entry point — `app.js`, `exam-entry.js`, `grade-entry.js` — content-hashes the output, e.g. `app.b294a7e2.js`, and rewrites `index.html`/`exam.html`/`grade.html` to reference the hashed files), all into a git-ignored `dist/`. **On Vercel, `buildCommand` is `npm run build` and `outputDirectory` is `dist`** — production serves this hashed `esbuild` bundle, not the raw repo root as-is.

**`npm run dev` (`npx serve .`) does not correctly load the app as it currently stands**: `js/app.js` does `import '../lib/services/badge-service.ts'` directly, and a plain static file server serves that `.ts` file to the browser unmodified instead of stripping the TypeScript — only `esbuild` (inside `npm run build`) does that transform. To check a change in an actual browser, either run `npm run build && npx serve dist` and open that, or verify the specific behavior via a `vitest` test instead of the raw dev server.

### Config generation (important)

`config.js` is **git-ignored and generated** by `build-config.js` from `.env` (copy `.env.example` → `.env`). Never edit `config.js` by hand — it is overwritten on every build. It exposes two globals to the frontend: `SUPABASE_CONFIG` (`url`, `anonKey`) and `NLC_CONFIG` (`clientId`, `issuer`, `memberHubUrl`, `scopes`).

## Cache-busting (critical — read before editing JS/CSS)

The app aggressively fights stale caches because church members run it on mobile PWAs:

- `index.html` itself only carries four `?v=` tags now: three CSS `<link>`s and the single `<script src="js/app.js?v=...">` (there's only one script tag — see [Architecture](#architecture)). Most JS cache-busting now happens *inside* the entry scripts instead:
  - Core eagerly-imported files (`config.js`, `state.js`, `db.js`, `auth.js`, `utils.js`, …) each carry their own `?v=YYYYMMDD_label` on the `import './x.js?v=...'` line inside `js/app.js` / `js/exam-entry.js` / `js/grade-entry.js`. Bump the one in every entry file that imports the file you changed — a shared file like `db.js` needs the same bump repeated in all three.
  - The lazy tab modules (`home.js`, `bible.js`, `plan.js`, `admin.js`, `profile.js`, `team-registration.js`) don't carry individual version strings — they're all versioned together by one shared `buildVersion` string built into `js/app.js`. Changing any one of them requires bumping that shared string, or every already-open client keeps serving its old cached copy of that specific module indefinitely.
  - **`npm run bump -- <label>`** (`scripts/bump-version.mjs`) rewrites all of the above in one shot — prefer it over hand-editing individual `?v=` strings.
  - This discipline is what actually matters in dev and for `index.html`'s own tags. In production, `app.js`/`exam-entry.js`/`grade-entry.js` get a real content hash from `scripts/bundle.mjs` on every deploy (e.g. `app.b294a7e2.js`), so those three specific files can never go stale from a forgotten bump — but everything else (lazy tab modules, CSS, the core-file `?v=` strings) still relies on this manual/`npm run bump` discipline even in production, because `bundle.mjs` copies them into `dist/` unhashed.
- `sw.js` is a thin, module-based Service Worker. It delegates cache behavior to `js/pwa/CacheManager.js`; never put business logic directly in lifecycle handlers.
- Cache only same-origin static assets and public Bible API responses. Authentication, Supabase/NLC, rankings, member data, and admin data must bypass Service Worker caching.
- Authenticated reading-log writes may be queued in IndexedDB by `PwaCoordinator`; credentials are never persisted in the queue. Background Sync asks an open authenticated client to flush the queue.
- `vercel.json` must keep `/`, `/index.html`, and `/sw.js` non-immutable. Hashed app bundles and versioned runtime modules may use immutable caching.
- See `docs/pwa-architecture.md` before changing caching or offline synchronization.
## Architecture

### Entry points and script loading (hybrid: legacy globals + real ES modules)

There are **four separate static HTML entry points**, each bootstrapping its own single `<script type="module">` — there is no `main.js`:
- `index.html` → `js/app.js` (the main SPA: all tabs, PWA/offline, onboarding).
- `exam.html` → `js/exam-entry.js` → mounts `js/modules/exam.js` (`mountExamRunner`).
- `grade.html` → `js/grade-entry.js` → mounts `js/modules/grading.js` (`mountGradingWorkspace`).
- `repair.html` — static cache-recovery fallback page (see `window.showAppStyleRecovery` in `index.html`).

Each entry script starts with a fixed, order-dependent chain of plain side-effect `import './x.js'` statements for the shared "core" files: `config.js` → `data/bible_data.js` → `data/bible_verse_counts.js` → `copy/zh-Hant.js` → `data/church_campaign.js` → `design/design-tokens.js` → `design/design-system-helpers.js` → `design/icon-registry.js` → `design/icons.js` → `state.js` → `auth.js` (+ `auth-launch.mjs`) → `db.js` → `utils.js` → `gamification.js`. This is real ES module syntax now (`type="module"`, `import`), **not** separate `<script>` tags — but `state.js`/`db.js`/`auth.js`/`utils.js`/`gamification.js` are still written pre-ESM style: they attach their API to `window` (`window.state = state`, `window.db = db`, …) instead of exporting it, and every consumer — including modules loaded much later — reads them back as bare identifiers (`state.activePlan`, `db.foo()`) or via `typeof fn === "function"` guards. This works because a module's unresolved free variables still fall through to the shared global object, same as a classic script. **The load order above is still load-bearing**: these files run once, in sequence, to populate that shared surface, and later code assumes it's already there.

Everything built more recently (`js/modules/*.mjs`, `js/data/*.mjs`, `js/pwa/*.js`) is a real ES module with proper named `export`/`import` and no `window` involved — prefer this style for new cross-file logic instead of adding another `window.foo`.

Tab views are **not** loaded eagerly at boot. `js/app.js` lazy-loads `js/modules/home.js`, `bible.js`, `plan.js`, `admin.js`, `profile.js`, `team-registration.js` on first use via an internal `loadModule(name, path)` helper — dynamic `import()`, retried on failure, cached in `moduleCache`, then calls the module's exported `init()`. (There is no `js/views/` directory — view/tab controllers live in `js/modules/`.) Each still carries its own `?v=` cache-bust query string that must be bumped on change; it just isn't fetched until the user opens that tab.

### Central state

`js/state.js` defines a single global `state` object (current user, org structure, active plans, reading logs, reader state, highlights, chart instances, admin filters) plus:
- `CHURCH_PLAN_PRESETS` — the hardcoded quarterly plan definitions (books + monthly breakdown for 2026–2027).
- `appRouter` — tab/view switcher (`switchTab`, `goBack`, `updateNavigationChrome`). Views are `.view-pane` sections toggled by `.active`; there is no URL routing.
- Theme management (light/dark/warm) persisted to `localStorage`.
- `escapeHTML()` — use this for any user-supplied string rendered into innerHTML.

### Data layer — the dual-client shim (`js/db.js`, ~6,100 lines)

`db.js` is the entire data-access layer (grown well past its original size — budget accordingly when estimating changes here). The key design: `state.supabase` is **either** a real Supabase client **or** an `NlcDataClient` shim, chosen at runtime by login method. Both expose the same `.from(table).select().eq()...` chainable API so callers don't care which is active:

- **Google/email login (dev/localhost only):** real `@supabase/supabase-js` client, RLS-enforced.
- **NLC Logto SSO (production):** `createNlcDataClient()` returns a shim whose `NlcQueryBuilder` serializes queries to JSON and POSTs them to the `nlc-data` Edge Function, which verifies the Logto token and uses the service role. This exists because the app uses **church Logto auth, not Supabase Auth**, so RLS can't see a Supabase JWT.

When adding data access, use the `state.supabase.from(...)` builder so it works in both modes. Note the shim only implements a subset of PostgREST (`select/insert/update/delete/upsert/eq/is/in/or/order/limit/single/maybeSingle`) — a query chain that works against the real client in dev can silently misbehave through the shim in production; there's no automated check that the two stay behaviorally equivalent.

### Auth (`js/auth.js`)

Logto OIDC + PKCE client for NLC SSO. Does discovery on `issuer`, handles the redirect callback, stores tokens in `localStorage` (`nlc_*` keys), and exchanges the Logto token for a Supabase profile via the `nlc-session` Edge Function. `auth.getValidAccessToken()` transparently refreshes; `db.js` retries once on 401.

### Bible text (`js/data/bible_data.js`)

Chapter text is fetched live from public Bible APIs (bible-api.com, bolls.life) with `assertCompleteEnough()` validation (must be Chinese, not truncated to 10 verses) and a small hardcoded `BIBLE_FALLBACK` for offline/failure. `bible_verse_counts.js` holds per-chapter verse counts. `CHURCH_PLAN_PRESETS` book names are Traditional Chinese; `BOLLS_BOOK_CODES` maps English names to API codes.

### Tab modules (`js/modules/`, lazy-loaded — see above)

- `home.js` — dashboard tab: verse of the day, announcements, devotional highlights.
- `bible.js` — immersive Bible reader: highlights, TTS, font/version controls.
- `plan.js` (**~10,300 lines** — by far the largest file in the app) — plan list, plan detail, daily task checklists, admin plan CRUD, inline reader, **and** the Chart.js personal/group/admin stats & leaderboard dashboards (there is no separate `stats.js`; it's all in here).
- `admin.js` (~4,300 lines) — admin user/org management, most of "系統管理".
- `profile.js` — account settings, badge wall.
- `team-registration.js` — team join/switch flows.
- `exam.js` / `grading.js` — mounted from the standalone `exam.html` / `grade.html` entry points, not from `app.js`.

## Backend (`supabase/`)

- **Active schema:** `supabase/migrations/` starting at `0001_clean_schema.sql`. Core tables: `profiles` (stable user record), `user_identities` (links login methods → one profile), `reading_plans`, `reading_logs`, `devotional_notes`, `global_plans`, `church_announcements`, and org tables (`great_regions`, `pastoral_zones`, `small_groups`). RLS resolves the caller via `current_profile_id()`.
- `supabase/migrations_legacy/` — old test-period migrations, kept for reference only. Do not replay on a fresh project.
- **Edge Functions** (`supabase/functions/`): `nlc-session` (verifies Logto token, upserts profile/identity with service role) and `nlc-data` (per-request Logto verification + server-side table/action allowlist, then service-role DB access). Both must have `verify_jwt = false` because the bearer is a Logto token, not a Supabase JWT. See `supabase/functions/README.md` for required secrets.
- The `profiles`/`user_identities` split is intentional: it prevents data loss when a user switches login method (e.g. Google → NLC Logto). First admin is promoted manually via SQL (see `supabase/README_clean_setup.md`).
- **New SQL functions default to PUBLIC-executable — revoke explicitly in the same migration, every time.** Postgres grants `EXECUTE` on every newly created function to the `PUBLIC` pseudo-role by default, and `anon` inherits it *transitively* through that — `REVOKE EXECUTE ... FROM anon` alone is a no-op against a `PUBLIC` grant. This exact gap let ~29 functions stay silently anon-callable through two cleanup attempts (`0173`, `0177`) before a third, broader sweep (`0182_revoke_public_function_execute_sweep3.sql`) finally caught them by checking `has_function_privilege('anon', ..., 'EXECUTE')` instead of trusting a role-specific grant list. Don't rely on the next periodic sweep to catch it again — every `CREATE FUNCTION`/`CREATE OR REPLACE FUNCTION` in a new migration must be followed immediately by an explicit grant:
  ```sql
  CREATE OR REPLACE FUNCTION public.some_new_fn(...) ... AS $$ ... $$;
  REVOKE ALL ON FUNCTION public.some_new_fn(...) FROM PUBLIC;
  GRANT EXECUTE ON FUNCTION public.some_new_fn(...) TO authenticated; -- omit entirely (service_role only) if it must never be called directly by a client
  ```
  If the function is `SECURITY DEFINER` and performs a privileged mutation (i.e. it bypasses RLS), do **not** grant `authenticated` unless the function is genuinely meant to be invoked directly by the client — granting `authenticated` on a `SECURITY DEFINER` function that expects to only ever be reached through `nlc-data`'s allowlist/`applyForcedScope` is exactly the "direct RPC bypass" vulnerability shape already fixed more than once (`d317a12`, `485679a`, `bc09eff`). Default to `service_role`-only for those.

## Design system

See `docs/design-system.md`. Satellite brand color is **`#04A9D2`** (`--color-brand`; legacy alias `--primary-color`). Rules: no gradient fills on UI chrome (flat colors only), content-first calm reader, three themes (light/dark/warm-sepia). Typography uses **medium (500)** for emphasis and **normal (400)** for body — avoid 600–900 weights on chrome. Neutral shadows only, no brand-tinted glows. Icons are **Lucide** via `data-icon` / `renderIcon()`; prefer these over emoji. UI copy is Traditional Chinese (see `js/copy/zh-Hant.js`).

---

## 💡 Key Architectural Guidelines & Anti-Bug Patterns

Detailed Skill Documentation is persisted at `.agents/skills/bible-study-dev-guidelines/SKILL.md`.

1. **Security & Forced Scope**:
   - Edge Functions (`nlc-data`) and RPC functions must enforce explicit `user_id` and `plan_id` filtering (`applyForcedScope`) on writes/deletes to prevent accidental cross-tenant data mutation.
   - Every new SQL function must explicitly `REVOKE ALL ... FROM PUBLIC` in the same migration it's created in — see the "New SQL functions default to PUBLIC-executable" rule under [Backend](#backend-supabase). Don't wait for the next Security Advisor sweep to catch it.

2. **Scroll State Preservation**:
   - When re-rendering container DOM (`innerHTML = ""`, e.g. `renderHorizontalDateStrip`), read `.scrollTop`/`.scrollLeft` beforehand and restore immediately after DOM update to prevent layout jumps.

3. **Async Race-Condition & Session Counter**:
   - `speechSynthesis.cancel()` triggers ghost `onend`/`onerror` events asynchronously.
   - Use a global `currentAudioSessionId` counter. In all async callbacks, check `if (sessionId !== currentAudioSessionId) return;` to instantly kill stale events.

4. **Natural Neural TTS Voice Selection**:
   - Prefer voices containing `Natural`, `Neural`, `Online`, `Ting-Ting`, `Samantha`, `HsiaoChen`, `YunJhe`.
   - Automatically match voice language: `zh-TW` for Chinese versions (`CUNP`, `RCUV`, `CUV`) and `en-US`/`en-GB` for English versions (`ESV`, `NIV`, `NLT`).

5. **User-Centric UI/UX Controls**:
   - Use Picker Modals (`#bible-version-picker-modal`) with clear checkmarks instead of single-button infinite loops when options > 3.
   - Keep bottom-of-page auto-read tracking silent without intrusive toast/modal subtitles.
   - Mutate memory state (`ch.isRead`, `ch.isReadR1`) synchronously upon log updates and recalculate plan progress on returning to plan view for instant reactivity without page reloads.
