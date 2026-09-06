import { describe, expect, it } from "vitest";
import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const root = dirname(dirname(fileURLToPath(import.meta.url)));
const edge = readFileSync(join(root, "supabase", "functions", "nlc-data", "index.ts"), "utf8");
const db = readFileSync(join(root, "js", "db.js"), "utf8");

describe("nlc-data: batch action (Edge Function)", () => {
  it("accepts action:'batch' without requiring a top-level table", () => {
    const guard = edge.match(/if \(!\[[^\]]*\]\.includes\(action\) && \(!table/);
    expect(guard, "missing_table guard line").toBeTruthy();
    expect(guard[0]).toContain('"batch"');
  });

  it("reuses ONE resolved profile + one pipeline per query, in request order", () => {
    const branch = edge.slice(edge.indexOf('if (action === "batch")'), edge.indexOf('if (action === "send_care_reminder")'));
    expect(branch).toContain("Array.isArray(body.queries)");
    expect(branch).toContain("missing_queries");
    expect(branch).toContain("batch_too_large");
    expect(branch).toMatch(/queries\.length > 25/);
    // sequential loop through the shared pipeline, results pushed in order
    expect(branch).toMatch(/for \(const spec of queries\)/);
    expect(branch).toContain("await runSelectPipeline(spec || {}, profile, supabaseAdmin)");
    expect(branch).toContain("return jsonResponse({ data: results })");
    // resolveProfile / auth verification happens once, before the action dispatch
    expect(edge.indexOf("const profile = await resolveProfile")).toBeLessThan(edge.indexOf('if (action === "batch")'));
  });

  it("is read-only: a non-select spec is rejected in its own slot, others still run", () => {
    const branch = edge.slice(edge.indexOf('if (action === "batch")'), edge.indexOf('if (action === "send_care_reminder")'));
    expect(branch).toMatch(/spec\.action && spec\.action !== "select"/);
    expect(branch).toContain("batch_read_only");
    // one throwing query is caught per-slot, never aborts the batch
    expect(branch).toMatch(/catch \(queryErr\)[\s\S]*results\.push\(\{ error:/);
  });

  it("runSelectPipeline mirrors the single-query select pipeline (allowlist + forced scope + options)", () => {
    const fn = edge.slice(edge.indexOf("async function runSelectPipeline("), edge.indexOf("Deno.serve(async (req"));
    expect(fn).toContain('READ_TABLES.has(table) || canReportOwnSelect');
    expect(fn).toContain('return { error: "forbidden" }');
    expect(fn).toContain('isFeatureEnabled(supabaseAdmin, "pastoral_sharing_wall")');
    expect(fn).toContain('applyFilters(query, spec.filters || [])');
    expect(fn).toContain('await applyForcedScope(query, table, "select", profile, supabaseAdmin)');
    expect(fn).toContain("rangeFrom + 199");
    expect(fn).toContain("Math.min(200, Math.max(1, Number(spec.limit)");
    expect(fn).toMatch(/spec\.returning === "single"/);
    expect(fn).toMatch(/spec\.returning === "maybeSingle"/);
  });
});

describe("db.batchSelect (js/db.js)", () => {
  // Two definitions: the shim's (inside createNlcDataClient's return object) and
  // the top-level db method. Split the file at applyNlcProfile which sits between.
  const shimHalf = db.slice(db.indexOf("createNlcDataClient()"), db.indexOf("applyNlcProfile(profile, lockedFields"));
  const dbMethodHalf = db.slice(db.indexOf("Collapse `Promise.all"), db.indexOf("applyNlcProfile(profile, lockedFields"));

  it("the NLC shim collapses select builders into one action:'batch' POST", () => {
    const method = shimHalf.slice(shimHalf.indexOf("async batchSelect(builders) {"));
    expect(method).toContain("builder && builder.request");
    expect(method).toContain('throw new Error("batchSelect is read-only")');
    expect(method).toContain('callEdge({ action: "batch", queries })');
    // maps results back in order; a per-row error becomes { data:null, error:{message,code} }
    expect(method).toContain("queries.map((_, index)");
    expect(method).toContain("{ data: null, error: { message: row.error, code: row.code || null } }");
    // a whole-batch failure surfaces on every slot (like Promise.all rejecting)
    expect(method).toContain("return queries.map(() => ({ data: null, error }))");
  });

  it("top-level db.batchSelect falls back to individual builders on the real client", () => {
    expect(dbMethodHalf).toContain('typeof client.batchSelect === "function"');
    expect(dbMethodHalf).toContain("return client.batchSelect(list)");
    expect(dbMethodHalf).toContain("Promise.all(list.map(async (builder) =>");
  });

  it("batch requests are still retried on a transient 503 (read-only, idempotent)", () => {
    expect(db).toContain('request.action === "select" || request.action === "batch"');
  });
});

describe("db.batchSelect shim mapping — behaviour", () => {
  // Reconstruct the shim's batchSelect with a stubbed callEdge and exercise the
  // request-order mapping / per-row error / whole-batch error paths.
  function makeBatchSelect(callEdge) {
    return async function batchSelect(builders) {
      const list = Array.isArray(builders) ? builders : [];
      const queries = list.map((builder) => {
        const request = builder && builder.request;
        if (!request || !request.table) throw new Error("batchSelect expects NlcQueryBuilder select instances");
        if (request.action && request.action !== "select") throw new Error("batchSelect is read-only");
        return request;
      });
      if (!queries.length) return [];
      const { data, error } = await callEdge({ action: "batch", queries });
      if (error) return queries.map(() => ({ data: null, error }));
      const results = Array.isArray(data) ? data : [];
      return queries.map((_, index) => {
        const row = results[index] || { error: "batch_result_missing" };
        if (row.error) return { data: null, error: { message: row.error, code: row.code || null } };
        return { data: row.data, error: null };
      });
    };
  }
  const b = (table, action) => ({ request: { table, action: action || "select" } });

  it("maps results back positionally, preserving per-row success/error", async () => {
    let sent = null;
    const batchSelect = makeBatchSelect(async (req) => {
      sent = req;
      return { data: [
        { data: [{ id: 1 }] },
        { error: "forbidden" },
        { data: null },
      ] };
    });
    const out = await batchSelect([b("global_plans"), b("secret_table"), b("reading_logs")]);
    expect(sent).toEqual({ action: "batch", queries: [
      { table: "global_plans", action: "select" },
      { table: "secret_table", action: "select" },
      { table: "reading_logs", action: "select" },
    ] });
    expect(out).toEqual([
      { data: [{ id: 1 }], error: null },
      { data: null, error: { message: "forbidden", code: null } },
      { data: null, error: null },
    ]);
  });

  it("propagates a whole-batch failure onto every slot", async () => {
    const batchSelect = makeBatchSelect(async () => ({ error: { message: "登入狀態已失效" } }));
    const out = await batchSelect([b("global_plans"), b("profiles")]);
    expect(out).toEqual([
      { data: null, error: { message: "登入狀態已失效" } },
      { data: null, error: { message: "登入狀態已失效" } },
    ]);
  });

  it("rejects a write builder before any request is sent", async () => {
    let called = false;
    const batchSelect = makeBatchSelect(async () => { called = true; return { data: [] }; });
    await expect(batchSelect([b("reading_logs"), b("reading_logs", "insert")]))
      .rejects.toThrow("batchSelect is read-only");
    expect(called).toBe(false);
  });

  it("empty input short-circuits without a request", async () => {
    let called = false;
    const batchSelect = makeBatchSelect(async () => { called = true; return { data: [] }; });
    expect(await batchSelect([])).toEqual([]);
    expect(called).toBe(false);
  });
});
