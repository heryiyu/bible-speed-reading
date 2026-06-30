'use strict';

/**
 * Static checks for Phase 0 NLC ecosystem integration.
 * Run: npm run verify:integration
 */

const fs = require('fs');
const path = require('path');

const root = path.join(__dirname, '..');
const requiredFiles = [
  'docs/phase-0-integration.md',
  'docs/nlc-onboarding.md',
  'docs/supabase-logto-setup.md',
  'supabase/migrations/0010_nlc_ecosystem_profile_fields.sql',
  'supabase/migrations/0011_phase0_org_lock_reset.sql',
  'api/member-context.js',
  'api/auth/logout.js',
  'api/_lib/supabase.js',
  'api/_lib/logto.js',
  'api/_lib/member-hub.js',
  'js/auth.js',
];

let failed = 0;

function assert(condition, message) {
  if (!condition) {
    console.error(`FAIL: ${message}`);
    failed += 1;
  }
}

for (const rel of requiredFiles) {
  const full = path.join(root, rel);
  if (!fs.existsSync(full)) {
    console.error(`MISSING: ${rel}`);
    failed += 1;
  }
}

const authJs = fs.readFileSync(path.join(root, 'js/auth.js'), 'utf8');
assert(authJs.includes('applyIdentityContext'), 'applyIdentityContext in js/auth.js');
assert(!authJs.includes('applyContextToCurrentUser'), 'removed applyContextToCurrentUser from js/auth.js');
assert(!authJs.includes('org_fields_locked = true'), 'Phase 0 must not set org_fields_locked in js/auth.js');

const dbJs = fs.readFileSync(path.join(root, 'js/db.js'), 'utf8');
assert(dbJs.includes('syncIdentityContext'), 'syncIdentityContext in js/db.js');
assert(dbJs.includes('shouldSyncIdentity'), 'shouldSyncIdentity in js/db.js');
assert(!dbJs.includes('org_fields_locked: true'), 'Phase 0 must not set org_fields_locked in js/db.js upsert');

const profileJs = fs.readFileSync(path.join(root, 'js/views/profile.js'), 'utf8');
assert(profileJs.includes('nlcAuth.signIn'), 'nlcAuth.signIn in js/views/profile.js');
assert(!profileJs.includes('org_fields_locked'), 'profile view must not reference org_fields_locked in Phase 0');

const memberHubJs = fs.readFileSync(path.join(root, 'api/_lib/member-hub.js'), 'utf8');
assert(memberHubJs.includes('sanitizeIdentityContext'), 'sanitizeIdentityContext in api/_lib/member-hub.js');

const memberContextApi = fs.readFileSync(path.join(root, 'api/member-context.js'), 'utf8');
assert(memberContextApi.includes('sanitizeIdentityContext'), 'API uses sanitizeIdentityContext');
assert(memberContextApi.includes('phase: 0'), 'API returns phase 0 marker');

if (failed > 0) {
  console.error(`\nPhase 0 integration verification failed (${failed} issue(s)).`);
  process.exit(1);
}

console.log('Phase 0 integration verification passed.');
