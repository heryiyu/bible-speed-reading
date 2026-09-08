import { describe, expect, it } from "vitest";
import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const root = dirname(dirname(fileURLToPath(import.meta.url)));
const adminView = readFileSync(join(root, "components", "issue-report", "AdminReportView.tsx"), "utf8");
const drawer = readFileSync(join(root, "components", "issue-report", "ReportDrawer.tsx"), "utf8");

describe("回報對話：進去出得來", () => {
  it("『回報管理』的對話 pane 用 createPortal 掛到 document.body（跳出 #admin-section-content 的 z-index:200 堆疊脈絡，否則返回/關閉鍵被頂 bar 蓋住點不到）", () => {
    expect(adminView).toContain('import { createPortal } from "react-dom"');
    expect(adminView).toMatch(/\{openId && createPortal\(\s*<AdminThreadPane[\s\S]*?document\.body\s*\)\}/);
  });

  it("『泡泡球』回覆模式：自動開最新對話只做一次，按『返回列表』不會又被彈回對話", () => {
    // 病因：AdminMiniList 在開對話時被卸載，返回時重新掛載 → 內部 openedRef 重置
    // → autoOpenNewest 再次把最新對話彈開。守衛 ref 提升到 ReportDrawer。
    expect(drawer).toContain("const adminAutoOpenedRef = React.useRef(false)");
    expect(drawer).toContain("autoOpenNewest={!adminAutoOpenedRef.current}");
    expect(drawer).toContain("onOpen={(id) => { adminAutoOpenedRef.current = true; setAdminOpenId(id); }}");
    // 泡泡關閉後下次打開要恢復「自動開最新」
    expect(drawer).toMatch(/if \(!isOpen \|\| mode !== "admin"\) \{\s*setAdminOpenId\(null\);\s*adminAutoOpenedRef\.current = false;/);
  });

  it("AdminThreadPane 兩個結束鍵都還在（embedded=返回列表 / 非 embedded=關閉）", () => {
    expect(adminView).toContain('onClick={embedded ? (onBack || onClose) : onClose}');
    expect(adminView).toContain('aria-label={embedded ? "返回列表" : "關閉"}');
  });
});
