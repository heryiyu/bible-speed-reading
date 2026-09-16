// Pure participation/team-state model for joined plan cards.
//
// Extracted from plan.js so the variant logic is unit-testable in isolation:
// plan.js references runtime globals (state, db, ...) at module load and cannot
// be imported directly in tests, whereas this helper is pure and side-effect free.

export function getPlanParticipationModel(plan, contexts = []) {
  const normalizedContexts = Array.isArray(contexts) ? contexts.filter(Boolean) : [];
  const divisions = [3, 6];
  const joinedContexts = normalizedContexts.filter(context => context && context.team);
  const joinedContext = joinedContexts[0] || null;
  // Consider EVERY joined division, not just the first context, so a member who
  // is in both team sizes is not offered a division they already joined.
  const joinedDivisions = new Set(
    joinedContexts
      .map(context => Number(context.team.division))
      .filter(division => !Number.isNaN(division))
  );
  const availableDivision = divisions.find(division => !joinedDivisions.has(division));

  if (!joinedContext) {
    return {
      variant: "solo",
      title: "個人讀經中",
      description: "尚未加入團隊",
      tone: "neutral",
      icon: "user",
      action: {
        label: "建立 / 加入團隊",
        division: 3,
        action: "join-team-division"
      }
    };
  }

  const team = joinedContext.team || {};
  const division = Number(team.division || 3);
  const memberCount = Number(team.memberCount || team.current_count || joinedContext.memberCount || 0);
  const capacity = Number(team.capacity || team.division || division);
  const isFull = capacity > 0 && memberCount >= capacity;
  // 隊名是使用者自訂的自由文字（長度、有沒有 emoji 都不可控），卡片只留
  // 「幾人組＋目前人數」這種可預期長度的狀態摘要，隊名點進「我的團隊」再看。
  const description = `${division}人組・${memberCount}/${capacity}`;

  if (availableDivision) {
    return {
      variant: "team-with-other-division-available",
      title: "團隊讀經中",
      description,
      tone: isFull ? "success" : "brand",
      icon: "people",
      action: {
        label: "我的團隊",
        division,
        action: "open-team-dialog"
      }
    };
  }

  return {
    variant: isFull ? "team-full" : "team-open",
    title: "團隊讀經中",
    description,
    tone: isFull ? "success" : "brand",
    icon: "people",
    action: {
      label: "我的團隊",
      division,
      action: "open-team-dialog"
    }
  };
}

export function shouldHidePlanTeamInviteShortcut(teamContextsByPlan = [], requiredDivisions = [3, 6]) {
  const plans = Array.isArray(teamContextsByPlan) ? teamContextsByPlan : [];
  const divisions = Array.from(new Set(
    (Array.isArray(requiredDivisions) ? requiredDivisions : [])
      .map(Number)
      .filter(Number.isFinite)
  ));

  if (plans.length === 0 || divisions.length === 0) return false;

  return plans.every(contexts => {
    const joinedDivisions = new Set(
      (Array.isArray(contexts) ? contexts : [])
        .filter(context => context && context.team)
        .map(context => Number(context.team.division))
        .filter(Number.isFinite)
    );
    return divisions.every(division => joinedDivisions.has(division));
  });
}
