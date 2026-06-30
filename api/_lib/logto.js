'use strict';

const { optionalEnv, requireEnv } = require('./env');

let discoveryCache = null;
let discoveryFetchedAt = 0;
const DISCOVERY_TTL_MS = 60 * 60 * 1000;

async function fetchDiscovery() {
  const now = Date.now();
  if (discoveryCache && now - discoveryFetchedAt < DISCOVERY_TTL_MS) {
    return discoveryCache;
  }

  const issuer = optionalEnv('LOGTO_ISSUER', 'https://sso.newlife.org.tw/oidc').replace(/\/$/, '');
  const res = await fetch(`${issuer}/.well-known/openid-configuration`);
  if (!res.ok) {
    throw new Error(`Logto discovery failed: ${res.status}`);
  }
  discoveryCache = await res.json();
  discoveryFetchedAt = now;
  return discoveryCache;
}

async function buildEndSessionUrl(postLogoutRedirectUri) {
  const discovery = await fetchDiscovery();
  const clientId = requireEnv('LOGTO_CLIENT_ID');
  const redirectUri = postLogoutRedirectUri || optionalEnv('APP_BASE_URL', '/');

  const url = new URL(discovery.end_session_endpoint);
  url.searchParams.set('client_id', clientId);
  url.searchParams.set('post_logout_redirect_uri', redirectUri);
  return url.toString();
}

module.exports = { fetchDiscovery, buildEndSessionUrl };
