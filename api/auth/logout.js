'use strict';

const { buildEndSessionUrl } = require('../_lib/logto');
const { optionalEnv } = require('../_lib/env');

module.exports = async function handler(req, res) {
  if (req.method === 'OPTIONS') {
    res.setHeader('Allow', 'POST, GET, OPTIONS');
    return res.status(204).end();
  }

  if (req.method !== 'POST' && req.method !== 'GET') {
    return res.status(405).json({ ok: false, error: 'Method not allowed' });
  }

  try {
    const body = req.body && typeof req.body === 'object' ? req.body : {};
    const redirectUri =
      body.postLogoutRedirectUri ||
      req.query?.post_logout_redirect_uri ||
      optionalEnv('APP_BASE_URL', '/');

    const endSessionUrl = await buildEndSessionUrl(redirectUri);
    return res.status(200).json({ ok: true, endSessionUrl });
  } catch (err) {
    console.error('[api/auth/logout]', err);
    return res.status(500).json({ ok: false, error: err.message || 'Failed to build logout URL' });
  }
};
