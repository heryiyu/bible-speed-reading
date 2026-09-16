/**
 * Design system helpers — browser bundle (window globals).
 * ESM twin: design-system-helpers.mjs (Vitest).
 */

import {
  countScheduleDaysCoveredByChapters,
  countExpectedScheduleDays,
  countRound1ChaptersRead,
} from "../data/schedule-progress.mjs";

// isChapterReadForRound / isPlanDayCompletedForRound / getNextReadingPlanDayPure /
// getExpectedPlanDayCountPure removed 2026-09-16: this whole chain only ever
// called each other (verified: none attached to window, none referenced
// outside this file) — the live consumer below, getPlanProgressStatusFromDesignSystem,
// uses schedule-progress.mjs's counters instead. Note plan.js has its own,
// separate, still-live local functions with the same two names
// (isChapterReadForRound/isPlanDayCompletedForRound) — those are unrelated
// and unaffected by this removal.

function getPlanProgressStatusFromDesignSystem(plan) {
  if (!plan || !plan.days || plan.days.length === 0) {
    return { label: "進度一致", badgeClass: "stat-badge--brand", diff: 0 };
  }

  const currentRound = plan.currentRound || 1;
  if (currentRound > 1) {
    // 第一遍之後：只顯示該使用者的輪次進度，不再算落後 / 超前。
    const roundProgress = Math.max(0, Math.min(100, Math.round(Number(plan.progress) || 0)));
    return {
      label: roundProgress > 0 ? "第" + currentRound + "遍完成" + roundProgress + "%" : "第" + currentRound + "遍進行中",
      badgeClass: "stat-badge--success",
      diff: 0,
    };
  }
  if (plan.isPlanCompleted) {
    return { label: "第一遍完成100%", badgeClass: "stat-badge--success", diff: 0 };
  }

  // 落後 / 超前一律對「教會原始日程」比（七日、不套 level / 個人休息日）。
  const baseline = (typeof window.getCanonicalStageScheduleDays === "function")
    ? window.getCanonicalStageScheduleDays(plan)
    : (plan.days || []);
  const completedBeforeNext = countScheduleDaysCoveredByChapters(baseline, countRound1ChaptersRead(plan));
  const expectedDays = countExpectedScheduleDays(baseline, plan.startDate);
  const diff = completedBeforeNext - expectedDays;

  if (diff > 0) {
    return { label: "超前 " + diff + "天", badgeClass: "stat-badge--success", diff };
  }
  if (diff < 0) {
    if (diff === -1) {
      return { label: "今日未完成", badgeClass: "stat-badge--danger", diff };
    }
    return { label: "落後 " + Math.abs(diff) + "天", badgeClass: "stat-badge--danger", diff };
  }
  return { label: "進度一致", badgeClass: "stat-badge--brand", diff: 0 };
}

const STAT_METRIC_CONFIG = {
  streak: { icon: "fire", modifier: "warning" },
  today: { icon: "bookOpen", modifier: "brand" },
  progress: { icon: "trendTwo", modifier: "success" },
  chapters: { icon: "journalText", modifier: "brand" },
  days: { icon: "calendarCheck", modifier: "neutral" },
  round: { icon: "refresh", modifier: "warning" },
  makeup: { icon: "exclamationCircle", modifier: "danger" },
  group: { icon: "people", modifier: "brand" },
};

function getStatMetricConfig(metricKey) {
  return (
    STAT_METRIC_CONFIG[metricKey] || {
      icon: "barChart",
      modifier: "neutral",
    }
  );
}

function getHonorBadgeItemClasses(isUnlocked) {
  return isUnlocked ? "honor-badge-item unlocked" : "honor-badge-item locked";
}

function getMobileNavAriaState(activeTabId, tabTargetId) {
  const isActive = activeTabId === tabTargetId;
  return {
    ariaSelected: isActive ? "true" : "false",
    ariaCurrent: isActive ? "page" : null,
    className: isActive ? "mobile-nav-btn active" : "mobile-nav-btn",
  };
}

window.getPlanProgressStatusFromDesignSystem = getPlanProgressStatusFromDesignSystem;
window.getStatMetricConfig = getStatMetricConfig;
window.getHonorBadgeItemClasses = getHonorBadgeItemClasses;
window.getMobileNavAriaState = getMobileNavAriaState;
