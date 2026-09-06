import { describe, expect, it } from "vitest";
import { readFileSync } from "node:fs";

const app = readFileSync("js/app.js", "utf8");
const home = readFileSync("js/modules/home.js", "utf8");
const db = readFileSync("js/db.js", "utf8");
const authJs = readFileSync("js/auth.js", "utf8");
const indexHtml = readFileSync("index.html", "utf8");
const examHtml = readFileSync("exam.html", "utf8");
const gradeHtml = readFileSync("grade.html", "utf8");
const planModule = readFileSync("js/modules/plan.js", "utf8");

describe("startup performance contract", () => {
  it("keeps React issue-report UI out of the initial app bundle", () => {
    expect(app).not.toContain("import React from 'react'");
    expect(app).not.toContain("from 'react-dom/client'");
    expect(app).not.toContain("../components/issue-report/IssueReportFab.tsx");
    expect(app).toContain("loadIssueReportUi");
    expect(app).toContain("ISSUE_REPORT_UI_MODULE_PATH");
    expect(app).toContain("import(path)");
  });

  it("uses the injected production build id instead of cache-busting every launch", () => {
    expect(app).toContain('if (!/^\\d{14}$/.test(buildVersion))');
    expect(app).not.toContain('buildVersion.includes("__BUILD_VERSION__")');
  });

  it("schedules the issue report UI before PWA initialization can delay it", () => {
    const reportSchedule = app.lastIndexOf("scheduleIssueReportUiLoad({ includeAdmin: false })");
    const pwaInitialization = app.indexOf("await initializePwa()");

    expect(reportSchedule).toBeGreaterThan(-1);
    expect(pwaInitialization).toBeGreaterThan(-1);
    expect(reportSchedule).toBeLessThan(pwaInitialization);
    expect(app).toContain("window.setTimeout(() => {");
    expect(app).toContain("window.requestIdleCallback(load, { timeout: 5000 })");
    expect(app).toContain("}, 3000)");
  });

  it("keeps registration helper modules lazy until their surfaces need them", () => {
    expect(app).not.toContain("import './modules/campaign-rule-editor.js");
    expect(app).not.toContain("import './modules/team-registration.js");
    expect(app).toContain("ensurePlanFeatureModulesLoaded");
    expect(app).toContain("ensureAdminFeatureModulesLoaded");
  });

  it("renders plan management before loading secondary admin bundles", () => {
    const adminBranch = app.slice(
      app.indexOf('} else if (tabId === "admin-view")'),
      app.indexOf("// ── 6. updateNavigationChrome", app.indexOf('} else if (tabId === "admin-view")'))
    );
    const planRender = adminBranch.indexOf("await mod.renderAdminPlanManagement()");
    const secondaryLoad = adminBranch.indexOf("void Promise.all([");

    expect(planRender).toBeGreaterThan(-1);
    expect(secondaryLoad).toBeGreaterThan(planRender);
    expect(adminBranch).not.toContain("await loadIssueReportUi({ includeAdmin: true })");
    expect(adminBranch).not.toContain("await ensureAdminFeatureModulesLoaded()");
  });

  it("does not block first dashboard render on care reminder fetches", () => {
    const forcedReminder = app.lastIndexOf("refreshCareReminderBadge({ force: true })");
    const firstTab = app.indexOf('await appRouter.switchTab(resumePlan ? "plan-view" : "dashboard-view")');

    expect(forcedReminder).toBeGreaterThan(-1);
    expect(firstTab).toBeGreaterThan(-1);
    expect(forcedReminder).toBeGreaterThan(firstTab);
  });

  it("does not block first dashboard render on organization-directory loading", () => {
    const firstTab = app.indexOf('await appRouter.switchTab(resumePlan ? "plan-view" : "dashboard-view")');
    const orgLoad = app.lastIndexOf("db.loadOrgStructure()");

    expect(firstTab).toBeGreaterThan(-1);
    expect(orgLoad).toBeGreaterThan(firstTab);
  });

  it("defers secondary dashboard widgets after the core dashboard card renders", () => {
    expect(home).toContain("scheduleDashboardSecondaryWork");
    expect(home).not.toContain("calculateAndRenderPersonalRankings();\n  renderPastoralZoneRankingList();\n  loadTodayDevotional();");
  });
});

describe("@supabase/supabase-js is off the critical path (A1)", () => {
  it("no HTML entry point loads the supabase CDN bundle with a static <script>", () => {
    for (const html of [indexHtml, examHtml, gradeHtml]) {
      expect(html).not.toMatch(/<script[^>]+cdn\.jsdelivr\.net\/npm\/@supabase\/supabase-js/);
    }
  });

  it("db.js loads the CDN bundle lazily via ensureSupabaseLib, pinned to an exact version", () => {
    expect(db).toContain("ensureSupabaseLib()");
    expect(db).toMatch(/cdn\.jsdelivr\.net\/npm\/@supabase\/supabase-js@\d+\.\d+\.\d+/);
    expect(db).not.toMatch(/cdn\.jsdelivr\.net\/npm\/@supabase\/supabase-js@2["']/);
  });

  it("createSupabaseClient awaits the lazy loader before touching the global", () => {
    const fn = db.slice(db.indexOf("async createSupabaseClient("), db.indexOf("async createSupabaseClient(") + 900);
    expect(fn).toContain("await this.ensureSupabaseLib()");
    expect(fn).toContain("supabase.createClient(");
  });

  it("db.init only eager-builds the real client on the localhost Google path", () => {
    const initSlice = db.slice(db.indexOf("state.supabaseConfig = { url: sbUrl"), db.indexOf("state.supabaseConfig = { url: sbUrl") + 600);
    expect(initSlice).toContain("if (allowGoogleLogin) {");
    expect(initSlice).toContain("state.supabase = await this.createSupabaseClient();");
    expect(initSlice).toContain("state.supabase = this.createNlcDataClient();");
  });

  it("the Supabase Auth session fallback is guarded so the NLC shim never hits .auth", () => {
    const fallback = db.slice(db.indexOf("// Fallback: Standard Supabase email/Google session"), db.indexOf("// Fallback: Standard Supabase email/Google session") + 500);
    expect(fallback).toContain("if (allowGoogleLogin) {");
    expect(fallback).toContain("state.supabase.auth.getSession()");
  });

  it("auth.resetLocalLogin resets to the shim instead of building a real client", () => {
    const reset = authJs.slice(authJs.indexOf("async resetLocalLogin()"), authJs.indexOf("async resetLocalLogin()") + 900);
    expect(reset).toContain("db.createNlcDataClient()");
    expect(reset).not.toContain("db.createSupabaseClient()");
  });
});

describe("Chart.js is off the critical path (A2)", () => {
  it("index.html no longer loads Chart.js with a static <script>", () => {
    expect(indexHtml).not.toMatch(/<script[^>]+cdn\.jsdelivr\.net\/npm\/chart\.js/);
  });

  it("plan.js lazy-loads Chart.js via ensureChartLib, pinned to an exact version", () => {
    expect(planModule).toContain("function ensureChartLib()");
    expect(planModule).toMatch(/cdn\.jsdelivr\.net\/npm\/chart\.js@\d+\.\d+\.\d+/);
    expect(planModule).not.toMatch(/cdn\.jsdelivr\.net\/npm\/chart\.js["']/);
  });

  it("renderOrUpdateChart self-heals when Chart is not loaded yet", () => {
    const fn = planModule.slice(planModule.indexOf("function renderOrUpdateChart("), planModule.indexOf("function renderOrUpdateChart(") + 700);
    expect(fn).toContain('if (typeof Chart === "undefined") {');
    expect(fn).toContain("ensureChartLib()");
    expect(fn).toContain("renderOrUpdateChart(key, canvasEl, config)");
  });

  it("warms the Chart.js fetch when a chart-bearing sub-view opens", () => {
    expect(planModule).toMatch(/async function renderPlanStatsView\(\)\s*\{\s*\n\s*ensureChartLib\(\)/);
    expect(planModule).toMatch(/async function renderPlanRankingView\(\)\s*\{\s*\n\s*ensureChartLib\(\)/);
    expect(planModule).toMatch(/async function updateStatsView\([^)]*\)\s*\{\s*\n\s*ensureChartLib\(\)/);
  });
});
