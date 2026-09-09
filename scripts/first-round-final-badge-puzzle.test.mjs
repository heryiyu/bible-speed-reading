import { describe, expect, it } from "vitest";
import { readFileSync } from "node:fs";

const utils = readFileSync("js/utils.js", "utf8");

// 鐵獎拼圖：四卷小徽章各顯示 iron-badge.svg（campaignStageNo 2）的一角，讀完
//那一卷才點亮那一塊；集滿四塊視覺上拼出完整的鐵獎圖。徽章牆格子跟徽章詳情
// 頁都要用同一份四角定義，順序對齊 FIRST_ROUND_FINAL_BOOK_BADGE_IDS（出/利/
// 民/申 = 左上/右上/左下/右下）。
describe("first-round-final badge puzzle quadrants", () => {
  it("defines all four book badges with a clip-path + transform-origin pair, one per corner", () => {
    const idx = utils.indexOf("const FIRST_ROUND_FINAL_QUADRANTS");
    expect(idx).toBeGreaterThan(-1);
    const body = utils.slice(idx, utils.indexOf("});", idx) + 3);
    for (const id of ["church_r1final_book_ex", "church_r1final_book_lev", "church_r1final_book_num", "church_r1final_book_deut"]) {
      expect(body, id).toContain(id);
    }
    const origins = ["top left", "top right", "bottom left", "bottom right"];
    for (const origin of origins) {
      expect(body, origin).toContain(origin);
    }
  });

  it("getFirstRoundFinalQuadrant is exposed globally for both render paths to share", () => {
    expect(utils).toContain("window.getFirstRoundFinalQuadrant = getFirstRoundFinalQuadrant");
  });

  it("badge wall tiles render the iron-badge quadrant, clipped+scaled, gated on unlock state", () => {
    const idx = utils.indexOf("if (badge.firstRoundFinalBook) {");
    expect(idx).toBeGreaterThan(-1);
    const body = utils.slice(idx, idx + 900);
    expect(body).toContain("getCampaignMedalPath(2)");
    expect(body).toContain("getFirstRoundFinalQuadrant(badge.id)");
    expect(body).toContain("transform: scale(2)");
    expect(body).toContain("overflow: hidden");
    expect(body).toContain("!isUnlocked");
  });

  it("the badge detail page reuses the same quadrant for the shared #detail-medal-image element and resets it for other badges", () => {
    const idx = utils.indexOf("const firstRoundFinalQuadrant = badge.firstRoundFinalBook");
    expect(idx).toBeGreaterThan(-1);
    const body = utils.slice(idx, idx + 2400);
    expect(body).toContain("getCampaignMedalPath(2)");
    expect(body).toContain('medalImage.style.transform = "scale(2)"');
    // must reset clip-path/transform back to "" in the non-quadrant branch,
    // since #detail-medal-image is one shared DOM node reused across every
    // badge the user opens — otherwise a later normal badge would inherit a
    // stale clip from whichever quadrant badge was viewed last.
    expect(body).toContain('medalImage.style.clipPath = "";');
    expect(utils).toContain('shield.style.overflow = firstRoundFinalQuadrant ? "hidden" : "";');
  });

  it("徽章牆的小徽章星等直接看遍數，會從 ★1–5 升到 💎6–8、👑9+（不被 maxStars 夾在 5）", () => {
    // getBadgeStarState.displayedStars 會被 maxStars(=5) 夾住；renderBadgeStars 必須
    // 對 firstRoundFinalBook 走跟 campaignStageNo 一樣的「直接看遍數」路徑，否則讀
    // 30 遍還是只顯示 ★5，跟徽章詳情頁（顯示「3 皇冠」）對不上。
    const fn = utils.slice(utils.indexOf("function renderBadgeStars(badge, compact"), utils.indexOf("function updateBadgeWallSummary"));
    expect(fn).toContain("badge.firstRoundFinalBook");
    expect(fn).toContain("Math.max(1, getFirstRoundFinalBookRounds(badge.id))");
    // 升級階梯本來就在 renderBadgeStars 裡：6→💎、9→👑、>10→3👑
    expect(fn).toContain("roundCount === 6");
    expect(fn).toContain("roundCount > 10");
  });
});
