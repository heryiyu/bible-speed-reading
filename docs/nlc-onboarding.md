# NLC Ecosystem Registration — Church Bible Speed Reading

Submit this packet to NLC IT to register Logto OIDC and scoped Member Hub data access.

Reference: [NLC MMS Developer Hub](https://nlc-b1ffeeba.mintlify.site/introduction)  
Implementation phase: **[Phase 0 integration plan](./phase-0-integration.md)** (identity only)

## Application

| Field | Value |
|-------|-------|
| App name (EN) | Church Bible Speed Reading |
| App name (ZH) | 教會速讀挑戰 |
| App type | Traditional Web (Supabase Auth custom OIDC client) |
| Product purpose | Church-wide Bible speed reading plans, personal progress, group/zone statistics, devotional notes, and role-scoped pastoral dashboards |

## Logto OIDC (Phase 0 — required)

| Field | Value |
|-------|-------|
| Issuer | `https://sso.newlife.org.tw/oidc` |
| Discovery | `https://sso.newlife.org.tw/oidc/.well-known/openid-configuration` |
| Requested scopes | `openid profile email phone` |
| Supabase custom provider id (proposed) | `custom:nlc-logto` |

### Redirect URIs

Replace `{SUPABASE_PROJECT_REF}` with your Supabase project reference.

| Environment | Callback URI |
|-------------|--------------|
| Production | `https://{SUPABASE_PROJECT_REF}.supabase.co/auth/v1/callback` |
| Local dev | Same Supabase callback (local app uses Supabase-hosted OAuth return) |

### Post-logout redirect URIs

| Environment | URI |
|-------------|-----|
| Production | `https://{YOUR_VERCEL_DOMAIN}/` |
| Local dev | `http://localhost:3000/` or `http://127.0.0.1:3000/` |

## Member Hub data access

Phase 0 uses Member Hub **optionally** for identity anchoring only. Local org tree and app RBAC remain authoritative in this app.

Do **not** grant service-role keys or browser cookie access.

### Phase 0 — request now

| Field | Use in this app |
|-------|-----------------|
| `identity.provider` | Anchor external identity (`logto`) |
| `identity.providerSubject` | Stable Logto `sub` stored on `profiles` |
| `identity.memberId` | Cross-system member reference |
| `profile.displayName` | Default display name when profile name is empty |

### Phase 1 — defer until Hub org model is ready

| Field | Future use |
|-------|------------|
| `profile.membershipStatus` | Feature gating |
| `roles`, `primaryRole` | Hub → app RBAC projection |
| `organization.homeNodeId`, `organization.homeNodeName` | Map to local org FKs |
| `apps` | Service access checks |

### Server-to-server access (optional in Phase 0)

| Field | Proposed value |
|-------|----------------|
| Integration identifier | `bible-speed-reading` |
| Context endpoint | Scoped server endpoint keyed by `identity.providerSubject` |
| Auth method | Service token issued to this app’s Vercel API bridge |

Login works without `MEMBER_HUB_SERVICE_TOKEN`; identity can be populated from Logto user metadata until Hub access is provisioned.

## Data handling notes (Phase 0)

- Logto proves **who** signed in.
- **Local** `great_regions` / `pastoral_zones` / `small_groups` and profile org fields define stats scope and RBAC.
- Hub org/role metadata may be **stored** on `profiles` for future use but is **not applied** to org placement or roles in Phase 0.
- Private devotional notes remain user-scoped via Supabase RLS.

## Contacts

- NLC IT: it@newlife.org.tw
- Integration docs: https://nlc-b1ffeeba.mintlify.site/sso/onboarding
