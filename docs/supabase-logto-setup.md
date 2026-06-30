# Supabase + Logto OIDC Setup (Phase 0)

Configure Supabase Auth to use NLC Logto as a custom OIDC provider so the browser keeps receiving a Supabase session JWT (preserving existing RLS).

Phase 0 scope: **identity only**. Local org tree and app RBAC are unchanged. See [phase-0-integration.md](./phase-0-integration.md).

## 1. Register the app with NLC IT

Use [docs/nlc-onboarding.md](./nlc-onboarding.md). Phase 0 requires Logto credentials; Member Hub service token is optional.

## 2. Create the custom OIDC provider in Supabase

In Supabase Dashboard → Authentication → Providers → add a **Custom OIDC** provider (or use the Admin API):

```js
await supabase.auth.admin.customProviders.createProvider({
  provider_type: 'oidc',
  identifier: 'custom:nlc-logto',
  name: 'NLC Logto SSO',
  client_id: '<from NLC IT>',
  client_secret: '<from NLC IT>',
  issuer: 'https://sso.newlife.org.tw/oidc',
  scopes: ['openid', 'profile', 'email', 'phone'],
})
```

Set the identifier to match `LOGTO_OIDC_PROVIDER` in `.env` (default: `custom:nlc-logto`).

## 3. Configure redirect URLs

In Logto (via NLC IT), allow Supabase’s callback:

```txt
https://<project-ref>.supabase.co/auth/v1/callback
```

In Supabase → Authentication → URL Configuration, add your app site URL(s):

- Production: `https://<your-vercel-domain>`
- Local: `http://localhost:3000`

## 4. Environment variables

Copy `.env.example` to `.env` and fill in values. Run `npm run build` to regenerate `config.js`.

Required for Phase 0 login: `SUPABASE_URL`, `SUPABASE_ANON_KEY`, `LOGTO_CLIENT_ID`, `APP_BASE_URL` (Vercel API logout).

Optional: `MEMBER_HUB_SERVICE_TOKEN` (identity enrichment from Hub when available).

## 5. Apply database migrations

```bash
supabase db push
# Includes 0010 (identity columns) and 0011 (Phase 0 org_fields_locked reset)
```

## 6. Verify Phase 0

1. Open the deployed app (not `?demo=true`).
2. Click **使用 NLC 帳號登入** and complete Logto sign-in.
3. Confirm `profiles.identity_subject` is populated.
4. Confirm 大區/牧區/小組 remain **editable** in profile settings.
5. Confirm admin role/org management still works.
6. Logout redirects through Logto end-session when `LOGTO_CLIENT_ID` is set on Vercel.

```bash
npm run verify:integration
```
