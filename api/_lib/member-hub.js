'use strict';

const { optionalEnv } = require('./env');

const IDENTITY_SYNC_TTL_MS = 24 * 60 * 60 * 1000;

/**
 * Fetch Member Hub context for a Logto subject via NLC-approved server credential.
 * Endpoint path is configurable until NLC IT provisions the integration route.
 */
async function fetchMemberContextForSubject(identitySubject) {
  const baseUrl = optionalEnv('MEMBER_HUB_BASE_URL', 'https://member.newlife.org.tw').replace(/\/$/, '');
  const serviceToken = optionalEnv('MEMBER_HUB_SERVICE_TOKEN');
  const contextPath = optionalEnv(
    'MEMBER_HUB_CONTEXT_PATH',
    '/api/integrations/bible-speed-reading/me/context'
  );

  if (!serviceToken) {
    return {
      ok: false,
      skipped: true,
      reason: 'MEMBER_HUB_SERVICE_TOKEN is not configured',
      context: null,
    };
  }

  const url = `${baseUrl}${contextPath.startsWith('/') ? contextPath : `/${contextPath}`}`;
  const res = await fetch(url, {
    method: 'GET',
    headers: {
      Authorization: `Bearer ${serviceToken}`,
      Accept: 'application/json',
      'X-Identity-Subject': identitySubject,
    },
  });

  if (!res.ok) {
    const body = await res.text().catch(() => '');
    return {
      ok: false,
      skipped: false,
      reason: `Member Hub responded ${res.status}: ${body.slice(0, 200)}`,
      context: null,
    };
  }

  const payload = await res.json();
  const context = payload.context || payload;
  return { ok: true, skipped: false, context };
}

/** Phase 0: identity fields for client + deferred metadata stored but not applied to org/role. */
function sanitizeIdentityContext(context) {
  if (!context || typeof context !== 'object') return null;

  return {
    identity: {
      provider: context.identity?.provider ?? null,
      providerSubject: context.identity?.providerSubject ?? null,
      memberId: context.identity?.memberId ?? null,
      email: context.identity?.email ?? null,
    },
    profile: {
      displayName: context.profile?.displayName ?? null,
    },
    deferred: {
      membershipStatus: context.profile?.membershipStatus ?? null,
      homeNodeId: context.organization?.homeNodeId ?? null,
      homeNodeName: context.organization?.homeNodeName ?? null,
      roles: Array.isArray(context.roles) ? context.roles : [],
      primaryRole: context.primaryRole ?? null,
      apps: Array.isArray(context.apps) ? context.apps : [],
    },
  };
}

/** Full context sanitizer — reserved for Phase 1. */
function sanitizeMemberContext(context) {
  if (!context || typeof context !== 'object') return null;

  return {
    identity: {
      provider: context.identity?.provider ?? null,
      providerSubject: context.identity?.providerSubject ?? null,
      memberId: context.identity?.memberId ?? null,
      email: context.identity?.email ?? null,
    },
    profile: {
      displayName: context.profile?.displayName ?? null,
      membershipStatus: context.profile?.membershipStatus ?? null,
    },
    organization: {
      homeNodeId: context.organization?.homeNodeId ?? null,
      homeNodeName: context.organization?.homeNodeName ?? null,
    },
    roles: Array.isArray(context.roles) ? context.roles : [],
    primaryRole: context.primaryRole ?? null,
    apps: Array.isArray(context.apps) ? context.apps : [],
  };
}

module.exports = {
  fetchMemberContextForSubject,
  sanitizeIdentityContext,
  sanitizeMemberContext,
  IDENTITY_SYNC_TTL_MS,
};
