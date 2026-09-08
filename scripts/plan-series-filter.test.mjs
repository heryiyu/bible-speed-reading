import { describe, expect, it } from "vitest";
import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const root = dirname(dirname(fileURLToPath(import.meta.url)));
const plan = readFileSync(join(root, "js", "modules", "plan.js"), "utf8");
const admin = readFileSync(join(root, "js", "modules", "admin.js"), "utf8");
const html = readFileSync(join(root, "index.html"), "utf8");
const css = readFileSync(join(root, "index.css"), "utf8");

describe("計畫分頁：系列篩選（會友端）", () => {
  it("index.html 有第二排系列 pill，預設整排隱藏、個別系列 pill 也隱藏", () => {
    expect(html).toContain('id="plan-list-series-pills"');
    expect(html).toMatch(/id="plan-list-series-pills"[^>]*hidden/);
    expect(html).toContain('data-series="all"');
    expect(html).toContain('data-series="campaign"');
    expect(html).toContain('data-series="devotional"');
    expect(html).toContain('data-series="group_meeting"');
    expect(html).toContain('data-series="other"');
    // 非「全部」的系列 pill 一開始都 hidden，由 plan.js 決定要不要顯示
    expect(html).toMatch(/data-series="campaign"\s+hidden/);
    expect(html).toMatch(/data-series="devotional"\s+hidden/);
    expect(html).toMatch(/data-series="group_meeting"\s+hidden/);
    expect(html).toMatch(/data-series="other"\s+hidden/);
  });

  it("getPlanSeries 把 plan_kind 分成 campaign / devotional / group_meeting / other", () => {
    const fn = plan.slice(plan.indexOf("function getPlanSeries("), plan.indexOf("function matchesPlanSeries("));
    expect(fn).toContain('kind === "devotional"');
    expect(fn).toContain('kind === "group_meeting"');
    expect(fn).toContain('kind === "church_campaign" || kind === "church_campaign_stage" || kind === "church_campaign_stage_cohort"');
    expect(fn).toContain('return "other"');
  });

  it("matchesPlanSeries：activePlanSeries=all 全過，否則比對 getPlanSeries", () => {
    expect(plan).toContain('if (!activePlanSeries || activePlanSeries === "all") return true;');
    expect(plan).toContain("return getPlanSeries(plan) === activePlanSeries;");
  });

  it("兩個清單都套 matchesPlanSeries", () => {
    expect(plan).toContain("plansToRender = plansToRender.filter(matchesPlanSeries);");
    expect(plan).toContain("return matchesPlanSearch(gp) && matchesPlanSeries(gp);");
    expect(plan).toContain("if (!matchesPlanSeries(plan)) return false;");
  });

  it("整排 pill 只在「靈修」或「小組」任一系列可見時才顯示（審核未過 = 整排藏）", () => {
    const fn = plan.slice(plan.indexOf("function updateSeriesPillRowVisibility()"), plan.indexOf("function setActivePlanSeries("));
    expect(fn).toContain('const showRow = seriesSet.has("devotional") || seriesSet.has("group_meeting");');
    expect(fn).toContain("row.hidden = !showRow;");
    // devotional/group 走各自 visibility helper（內含 devotionGroupHidden 硬閘）
    const visFn = plan.slice(plan.indexOf("function getVisiblePlanSeriesSet()"), plan.indexOf("function updateSeriesPillRowVisibility()"));
    expect(visFn).toContain("isDevotionalPlanVisibleToUser(plan)");
    expect(visFn).toContain("isGroupMeetingPlanVisibleToUser(plan)");
    // 個別 pill：沒該系列計畫就 hidden
    expect(fn).toContain('btn.hidden = series !== "all" && !seriesSet.has(series);');
  });

  it("選擇記 sessionStorage，pill 被藏時退回「全部」", () => {
    expect(plan).toContain("sessionStorage.getItem('plan_list_series')");
    expect(plan).toContain('sessionStorage.setItem("plan_list_series", activePlanSeries);');
    expect(plan).toContain('setActivePlanSeries("all", { rerender: false })');
  });

  it("pill 點擊有綁 setActivePlanSeries", () => {
    expect(plan).toContain('document.querySelectorAll("#plan-list-series-pills .pill-btn--series")');
    expect(plan).toContain('setActivePlanSeries(pill.getAttribute("data-series"))');
  });

  it("CSS：系列 pill 字級 ≥ 14px、hidden 屬性有效", () => {
    const rule = css.match(/\.pill-btn--series \{([\s\S]*?)\}/)?.[1] || "";
    expect(rule).toContain("font-size: 0.875rem;");
    expect(css).toContain(".pill-btn--series[hidden] {");
    expect(css).toContain(".status-pills-row--series[hidden] {");
  });
});

describe("系統管理：計畫篩選下拉依子分頁過濾", () => {
  const fn = admin.slice(admin.indexOf("async function syncManagementPlanSelectForSubtab()"),
    admin.indexOf("export async function renderAdminPlanManagement()"));

  it("devotions → 只列 devotional，group-meeting → 只列 group_meeting，其餘 → 排除這兩類", () => {
    expect(fn).toContain("all.filter(p => managementPlanKindOf(p) === 'devotional')");
    expect(fn).toContain("all.filter(p => managementPlanKindOf(p) === 'group_meeting')");
    expect(fn).toContain("k !== 'devotional' && k !== 'group_meeting'");
  });

  it("devotions/group-meeting 的 onchange 驅動各自的 selectedPlanId + 重繪，不走 selectManagementPlan", () => {
    expect(fn).toContain("adminDevotionSelectedPlanId = pid");
    expect(fn).toContain("adminGroupMeetingSelectedPlanId = pid");
    expect(fn).toContain("const render = isDevotion ? renderAdminDevotionPlan : renderAdminGroupMeetingPlan;");
    expect(fn).toContain("await loadActiveAdminPlanSubtab(false)");
    // 其餘子分頁維持 selectManagementPlan
    expect(fn).toContain("select.onchange = () => selectManagementPlan(select.value);");
    expect(fn).toContain("await selectManagementPlan(select.value);");
  });

  it("切子分頁時（setAdminSection）與進管理頁時都重新過濾下拉", () => {
    expect(admin).toContain("if (options.loadData !== false) void syncManagementPlanSelectForSubtab();");
    expect(admin).toContain("await syncManagementPlanSelectForSubtab();");
    // 舊的一次性 loadActiveAdminPlanSubtab 直呼已被 sync 取代
    expect(admin).not.toContain("if (options.loadData !== false && state.activePlan) void loadActiveAdminPlanSubtab(false);");
  });

  it("空狀態文案依子分頁不同", () => {
    expect(fn).toContain("目前沒有每日靈修計畫");
    expect(fn).toContain("目前沒有小組聚會計畫");
  });
});
