// NLC ecosystem auth helpers (Logto via Supabase custom OIDC + API bridge)
// Phase 0: identity anchoring only — local org/role logic stays in this app.

const nlcAuth = {
  getOidcProvider() {
    if (typeof APP_CONFIG !== 'undefined' && APP_CONFIG.logtoOidcProvider) {
      return APP_CONFIG.logtoOidcProvider;
    }
    return 'custom:nlc-logto';
  },

  getRedirectTo() {
    return window.location.origin + window.location.pathname;
  },

  async signIn() {
    if (!state.supabase) {
      throw new Error('Supabase 未初始化。請確認已設定連線資訊或檢查網路狀態！');
    }
    const provider = this.getOidcProvider();
    const { error } = await state.supabase.auth.signInWithOAuth({
      provider,
      options: {
        redirectTo: this.getRedirectTo(),
      },
    });
    if (error) throw error;
  },

  async signOut() {
    if (state.isSupabaseMode && state.supabase) {
      await state.supabase.auth.signOut();
    }

    try {
      const redirectUri = this.getRedirectTo();
      const res = await fetch('/api/auth/logout', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ postLogoutRedirectUri: redirectUri }),
      });
      if (res.ok) {
        const data = await res.json();
        if (data.endSessionUrl) {
          window.location.href = data.endSessionUrl;
          return;
        }
      }
    } catch (err) {
      console.warn('Logto end-session redirect unavailable:', err);
    }
  },

  /** Reserved for Phase 1 Hub role projection — not used in Phase 0. */
  mapPrimaryRoleToAppRole(primaryRole, roles) {
    const roleList = Array.isArray(roles) ? roles : [];
    if (roleList.includes('senior_pastor')) return 'senior_pastor';
    if (roleList.includes('great_zone_leader')) return 'great_zone_leader';
    if (roleList.includes('zone_leader')) return 'zone_leader';
    if (roleList.includes('group_leader')) return 'group_leader';
    if (roleList.includes('admin')) return 'admin';

    switch (primaryRole) {
      case 'admin':
        return 'admin';
      case 'pastor':
        return 'senior_pastor';
      case 'finance':
        return 'member';
      case 'member':
      default:
        return 'member';
    }
  },

  /**
   * Phase 0: apply identity + stored Hub metadata only.
   * Does NOT modify great_region, pastoral_zone, small_group, role, or org_fields_locked.
   * @returns {object|null} Fields to persist on profiles (identity columns only)
   */
  applyIdentityContext(context, options = {}) {
    if (!context) return null;

    const hasLocalName = options.hasLocalName ?? !!(
      state.currentUser.name &&
      state.currentUser.name.trim() &&
      state.currentUser.name !== '新使用者'
    );
    const syncedAt = new Date().toISOString();
    const deferred = context.deferred || {};

    if (context.identity?.provider) {
      state.currentUser.identity_provider = context.identity.provider;
    }
    if (context.identity?.providerSubject) {
      state.currentUser.identity_subject = context.identity.providerSubject;
    }
    if (context.identity?.memberId) {
      state.currentUser.member_id = context.identity.memberId;
    }

    if (deferred.membershipStatus) {
      state.currentUser.membership_status = deferred.membershipStatus;
    }
    if (deferred.homeNodeId) {
      state.currentUser.home_node_id = deferred.homeNodeId;
    }
    if (deferred.homeNodeName) {
      state.currentUser.home_node_name = deferred.homeNodeName;
    }
    if (deferred.primaryRole) {
      state.currentUser.hub_primary_role = deferred.primaryRole;
    }
    if (Array.isArray(deferred.roles)) {
      state.currentUser.hub_roles = deferred.roles;
    }

    state.currentUser.member_context_synced_at = syncedAt;

    const payload = {
      identity_provider: state.currentUser.identity_provider,
      identity_subject: state.currentUser.identity_subject,
      member_id: state.currentUser.member_id,
      membership_status: state.currentUser.membership_status,
      home_node_id: state.currentUser.home_node_id,
      home_node_name: state.currentUser.home_node_name,
      hub_primary_role: state.currentUser.hub_primary_role,
      hub_roles: state.currentUser.hub_roles,
      member_context_synced_at: syncedAt,
      updated_at: syncedAt,
    };

    const displayName = context.profile?.displayName;
    if (displayName && !hasLocalName) {
      state.currentUser.name = displayName;
      payload.name = displayName;
    }

    return payload;
  },

  applyAuthUserIdentity(user) {
    if (!user) return null;

    const identitySubject =
      user.user_metadata?.provider_subject ||
      user.user_metadata?.sub ||
      user.app_metadata?.provider_subject ||
      null;

    if (identitySubject) {
      state.currentUser.identity_provider = 'logto';
      state.currentUser.identity_subject = identitySubject;
    }

    return {
      identity_provider: state.currentUser.identity_provider,
      identity_subject: state.currentUser.identity_subject,
    };
  },
};
