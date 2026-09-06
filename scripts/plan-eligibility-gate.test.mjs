import { describe, expect, it } from "vitest";
import { readFileSync } from "node:fs";

const read = path => readFileSync(new URL(`../${path}`, import.meta.url), "utf8");

const utils = read("js/utils.js");
const app = read("js/app.js");
const homeModule = read("js/modules/home.js");
const planModule = read("js/modules/plan.js");
const html = read("index.html");
const css = read("index.css");
const adminCss = read("css/admin-registration-statistics.css");
const admin = read("js/modules/admin.js");
const db = read("js/db.js");
const nlcData = read("supabase/functions/nlc-data/index.ts");
const migration = read("supabase/migrations/0069_name_review_approval.sql");

describe("profile name heuristic (js/utils.js)", () => {
  it("merges the placeholder-name lists and exports them for reuse", () => {
    expect(utils).toContain("尚未取得姓名");
    expect(utils).toContain("未命名使用者");
    expect(utils).toContain("教會肢體");
    expect(utils).toContain("window.INVENTED_DISPLAY_NAMES = INVENTED_DISPLAY_NAMES");
  });

  it("flags digits, emoji, and gibberish English, and exports isProfileNameValid", () => {
    expect(utils).toContain("function getProfileNameFlags(name)");
    expect(utils).toContain("PROFILE_NAME_DIGIT_PATTERN.test(trimmed)) flags.push(\"digits\")");
    expect(utils).toContain("PROFILE_NAME_EMOJI_PATTERN.test(trimmed)) flags.push(\"emoji\")");
    expect(utils).toContain("looksLikeGibberishEnglish");
    expect(utils).toContain("function isProfileNameValid(name)");
    expect(utils).toContain("window.getProfileNameFlags = getProfileNameFlags");
    expect(utils).toContain("window.isProfileNameValid = isProfileNameValid");
  });

  it("evaluates gibberish heuristic correctly for representative tokens", () => {
    const fn = new Function(`
      ${utils.match(/function looksLikeGibberishEnglish[\s\S]*?\n}/)[0]}
      return looksLikeGibberishEnglish;
    `)();
    expect(fn("bxfgh")).toBe(true); // no vowel
    expect(fn("aaaaa")).toBe(true); // tripled letter
    expect(fn("asdfgh")).toBe(true); // 5+ consonant run (asdfgh has no vowel anyway, still flagged)
    expect(fn("David")).toBe(false);
    expect(fn("Grace")).toBe(false);
    expect(fn("a")).toBe(false); // too short to judge
  });

  it("no longer defines a plan-tab eligibility gate — the check moved to login", () => {
    // 計畫資格改成只在登入時判斷（db.init → getUserOnboardingBlock → getLoginGateCopy）。
    expect(utils).not.toContain("function getPlanEligibilityBlock(");
    expect(utils).not.toContain("window.getPlanEligibilityBlock");
    expect(utils).not.toContain("getPlanEligibilitySoftState");
    expect(utils).not.toContain("planEligibilityVerifiedThisSession");
    expect(utils).not.toContain("plan_elig_hub_verified");
  });
});

describe("plan entry: eligibility judged at login only (js/app.js + js/db.js)", () => {
  it("plan-view switchTab branch renders the plan module directly, no eligibility re-check", () => {
    const planBranch = app.match(/\} else if \(tabId === "plan-view"\) \{[\s\S]*?\n {4}\} else if \(tabId === "stats-view"\)/);
    expect(planBranch, "plan-view switchTab branch").toBeTruthy();
    expect(planBranch[0]).not.toContain("getPlanEligibilityBlock");
    expect(planBranch[0]).not.toContain("renderPlanEligibilityGate");
    expect(planBranch[0]).not.toContain("getPlanEligibilitySoftState");
    expect(planBranch[0]).toContain("hidePlanEligibilityGate()");
    expect(planBranch[0]).toContain("loadModule('plan'");
  });

  it("guardPlanEligibility is a no-op so its existing call sites never block", () => {
    expect(app).toMatch(/function guardPlanEligibility\(\)\s*\{\s*return false;\s*\}/);
    expect(app).toContain("window.guardPlanEligibility = guardPlanEligibility");
    // Call sites stay (harmless no-op) — no need to touch home.js / plan.js.
    expect(homeModule).toMatch(/openActivePlanFromDashboard[\s\S]*guardPlanEligibility\(\)/);
    expect(planModule).toMatch(/openPlanChapterInReader[\s\S]*guardPlanEligibility\(\)/);
  });

  it("removes the dead plan-eligibility gate machinery from app.js", () => {
    expect(app).not.toContain("function renderPlanEligibilityGate");
    expect(app).not.toContain("function retryPlanEligibilityQuietly");
    expect(app).not.toContain("function getPlanEligibilityGateCopy");
    expect(app).not.toContain("function resetPlanNavigationForEligibilityGate");
    expect(app).not.toContain("function bindPlanEligibilityHubReturnSync");
    expect(app).not.toContain("resyncPlanEligibilityAfterHubReturn");
  });

  it("db.init evaluates the login gate right after a fresh member-context sync", () => {
    // 登入流程：同步 → getUserOnboardingBlock → getLoginGateCopy → 進 App 或停在登入卡
    const initSlice = db.slice(db.indexOf("if (auth.isLoggedIn())"), db.indexOf("if (auth.isLoggedIn())") + 2000);
    expect(initSlice).toContain("await this.syncNlcSessionWithSupabase(true)");
    expect(initSlice).toContain("const block = getUserOnboardingBlock(state.currentUser)");
    expect(initSlice).toContain("getLoginGateCopy(block");
    expect(initSlice).toContain("applyLoginGateView");
  });

  it("login gate copy still covers every fail-closed member-hub reason", () => {
    const gate = read("js/login-onboarding-gate.mjs");
    expect(gate).toContain('block.reason === "member_profile_required"');
    expect(gate).toContain('block.reason === "membership_application_required"');
    expect(gate).toContain('block.reason === "member_context_unavailable"');
    expect(gate).toContain('block.reason === "inactive_membership"');
  });
});

describe("admin name-review console (js/modules/admin.js + index.html)", () => {
  it("adds a name-review filter checkbox next to the existing incomplete-profile filters", () => {
    expect(html).toContain('id="admin-user-directory-filter-name-review"');
  });

  it("computes review status from the shared heuristic, excluding merely-empty names", () => {
    expect(admin).toContain("function getNameReviewFlags(profile)");
    expect(admin).toContain('getProfileNameFlags(profile.name).filter(flag => flag !== "empty")');
    expect(admin).toContain("function profileNameNeedsReview(profile)");
    expect(admin).toContain("profile.name_review_approved !== true");
  });

  it("reuses the merged placeholder set instead of a third hardcoded list", () => {
    expect(admin).toContain("window.INVENTED_DISPLAY_NAMES");
  });

  it("wires an approve action and an edit-and-approve action per flagged card", () => {
    expect(admin).toContain("admin-user-directory__name-review-approve");
    expect(admin).toContain("admin-user-directory__name-review-save");
    expect(admin).toContain("db.approveProfileName(profileId)");
    expect(admin).toContain("db.adminOverwriteProfileName(");
    expect(admin).toContain("function bindAdminUserDirectoryNameReviewActions(list)");
    expect(admin).toContain("bindAdminUserDirectoryNameReviewActions(list)");
  });

  it("styles the disabled/needs-review status badge (regression: --disabled had no matching CSS rule)", () => {
    expect(adminCss).toContain(".admin-user-directory__status--disabled");
  });
});

describe("admin write path for name review (js/db.js)", () => {
  it("requires the admin role for both approve and overwrite actions", () => {
    const approveFn = db.match(/async approveProfileName\(profileId\) \{[\s\S]*?\n {2}\},/);
    const overwriteFn = db.match(/async adminOverwriteProfileName\(profileId, name\) \{[\s\S]*?\n {2}\},/);
    expect(approveFn, "approveProfileName").toBeTruthy();
    expect(overwriteFn, "adminOverwriteProfileName").toBeTruthy();
    expect(approveFn[0]).toContain('getUserRoleCode(state.currentUser) !== "admin"');
    expect(overwriteFn[0]).toContain('getUserRoleCode(state.currentUser) !== "admin"');
    expect(approveFn[0]).toContain("name_review_approved: true");
    expect(overwriteFn[0]).toContain("name_review_approved: true");
  });
});

describe("name_review_approved column (migration 0069 + nlc-data)", () => {
  it("adds the column as NOT NULL DEFAULT false, consistent with the other profile flags", () => {
    expect(migration).toContain("ADD COLUMN IF NOT EXISTS name_review_approved BOOLEAN NOT NULL DEFAULT false");
  });

  it("exposes the column through PROFILE_SELECT so the client can read it", () => {
    const selects = [...nlcData.matchAll(/select\("([^"]*name_review_approved[^"]*)"\)/g)];
    expect(nlcData).toContain("name_review_approved");
    expect(nlcData.match(/PROFILE_SELECT = "[^"]*name_review_approved/)).toBeTruthy();
  });

  it("loads and applies the approval flag to every current-user profile path", () => {
    expect(db).toMatch(/from\("profiles"\)\.select\("[^"]*name_review_approved[^"]*"\)/);
    expect(db).toContain("state.currentUser.name_review_approved = profile.name_review_approved === true");
    expect(db).toContain("state.currentUser.name_review_approved = false");
  });

  it("resets the approval on self-service name changes so a stale approval cannot survive an edit", () => {
    const start = nlcData.indexOf('if (action === "save_profile")');
    const end = nlcData.indexOf('if (action === "insert"', start);
    expect(start, "save_profile branch start").toBeGreaterThan(-1);
    expect(end, "save_profile branch end").toBeGreaterThan(start);
    const saveProfileBranch = nlcData.slice(start, end);
    expect(saveProfileBranch).toContain("nameChanged");
    expect(saveProfileBranch).toContain("updatePayload.name_review_approved = false");
  });
});
