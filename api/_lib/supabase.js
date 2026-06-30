'use strict';

const { createClient } = require('@supabase/supabase-js');
const { requireEnv, optionalEnv } = require('./env');

function getSupabaseAdmin() {
  const url = requireEnv('SUPABASE_URL');
  const key = optionalEnv('SUPABASE_SERVICE_ROLE_KEY') || requireEnv('SUPABASE_ANON_KEY');
  return createClient(url, key, {
    auth: { persistSession: false, autoRefreshToken: false },
  });
}

async function getUserFromBearer(req) {
  const header = req.headers.authorization || req.headers.Authorization || '';
  const match = String(header).match(/^Bearer\s+(.+)$/i);
  if (!match) {
    return { user: null, error: 'Missing Authorization bearer token' };
  }

  const token = match[1].trim();
  const supabase = getSupabaseAdmin();
  const { data, error } = await supabase.auth.getUser(token);
  if (error || !data.user) {
    return { user: null, error: error?.message || 'Invalid or expired token' };
  }
  return { user: data.user, error: null, accessToken: token };
}

module.exports = { getSupabaseAdmin, getUserFromBearer };
