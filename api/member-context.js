'use strict';

const { getUserFromBearer, getSupabaseAdmin } = require('./_lib/supabase');
const { fetchMemberContextForSubject, sanitizeIdentityContext } = require('./_lib/member-hub');

module.exports = async function handler(req, res) {
  if (req.method === 'OPTIONS') {
    res.setHeader('Allow', 'GET, OPTIONS');
    return res.status(204).end();
  }

  if (req.method !== 'GET') {
    return res.status(405).json({ ok: false, error: 'Method not allowed' });
  }

  try {
    const { user, error: authError } = await getUserFromBearer(req);
    if (authError || !user) {
      return res.status(401).json({ ok: false, error: authError || 'Unauthorized' });
    }

    const supabase = getSupabaseAdmin();
    const { data: profile } = await supabase
      .from('profiles')
      .select('identity_provider, identity_subject, member_id')
      .eq('id', user.id)
      .maybeSingle();

    const identitySubject =
      profile?.identity_subject ||
      user.user_metadata?.provider_subject ||
      user.user_metadata?.sub ||
      user.app_metadata?.provider_subject ||
      null;

    if (!identitySubject) {
      return res.status(200).json({
        ok: true,
        synced: false,
        phase: 0,
        reason: 'No Logto subject available yet; profile bootstrap may still be pending',
        context: null,
      });
    }

    const hubResult = await fetchMemberContextForSubject(identitySubject);

    if (hubResult.skipped) {
      return res.status(200).json({
        ok: true,
        synced: false,
        phase: 0,
        reason: hubResult.reason,
        context: null,
      });
    }

    if (!hubResult.ok || !hubResult.context) {
      return res.status(502).json({
        ok: false,
        error: hubResult.reason || 'Failed to load Member Hub context',
      });
    }

    const context = sanitizeIdentityContext(hubResult.context);
    return res.status(200).json({ ok: true, synced: true, phase: 0, context });
  } catch (err) {
    console.error('[api/member-context]', err);
    return res.status(500).json({ ok: false, error: err.message || 'Internal server error' });
  }
};
