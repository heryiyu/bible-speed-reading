# Church Bible Speed Reading

教會速讀挑戰與統計系統 — a static PWA with Phase 0 NLC ecosystem integration (Logto SSO + identity anchoring).

## Quick start

```bash
cp .env.example .env
# Fill in Supabase and NLC integration values
npm install
npm run build
npm run dev
```

Local demo mode (no Supabase): `http://localhost:3000/?demo=true`

## NLC ecosystem integration (Phase 0)

| Layer | Phase 0 responsibility |
|-------|------------------------|
| Logto | Sign-in, logout, stable identity |
| Supabase Auth | Custom OIDC → session JWT for RLS |
| Member Hub | Optional identity enrichment (`memberId`, display name) |
| This app | Org tree, RBAC, reading data, stats (unchanged) |

Documentation:

- [Phase 0 integration plan](docs/phase-0-integration.md)
- [NLC registration packet](docs/nlc-onboarding.md)
- [Supabase + Logto setup](docs/supabase-logto-setup.md)
- [NLC MMS Developer Hub](https://nlc-b1ffeeba.mintlify.site/introduction)

## Verification

```bash
npm run verify:integration
```

## API routes (Vercel)

| Route | Purpose |
|-------|---------|
| `GET /api/member-context` | Phase 0 identity subset from Member Hub (optional) |
| `POST /api/auth/logout` | Logto end-session URL for cross-app logout |

Server-only env vars: see [.env.example](.env.example).
