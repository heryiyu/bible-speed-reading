import { describe, expect, it } from "vitest";
import { readFileSync } from "node:fs";

// 正規化換行：有些檔案在 Windows checkout 下是 CRLF，斷言一律用 \n 比對。
const read = path => readFileSync(new URL(`../${path}`, import.meta.url), "utf8").replace(/\r\n/g, "\n");
const migration = read("supabase/migrations/0155_devotion_video_sync.sql");
const fn = read("supabase/functions/sync-devotion-video/index.ts");
const readme = read("supabase/functions/README.md");

// 每日靈修影片自動抓取：教會 YouTube 頻道每天早上會上架當天的靈修影片，排程
// 每天固定時間讀 YouTube 官方公開 RSS（不用登入、不用 API 金鑰），把最新一支
// 影片填進「今天」那一天的 plan_devotion_days——但只在管理員還沒手動填過的
// 時候才動手，避免蓋掉管理員自己選的連結。
describe("devotion video sync migration (0155)", () => {
  it("only fills video_url when it is still blank, and is restricted to service_role", () => {
    expect(migration).toContain("CREATE OR REPLACE FUNCTION public.sync_devotion_day_video(");
    expect(migration).toContain("AND video_url IS NULL");
    expect(migration).toContain("GRANT EXECUTE ON FUNCTION public.sync_devotion_day_video(uuid, integer, text, text) TO service_role");
    expect(migration).not.toContain("GRANT EXECUTE ON FUNCTION public.sync_devotion_day_video(uuid, integer, text, text) TO authenticated");
  });

  it("schedules the sync once a day via pg_cron, guarded by a Vault-stored cron secret", () => {
    expect(migration).toContain("devotion_video_sync_cron_secret");
    expect(migration).toContain("functions/v1/sync-devotion-video");
    expect(migration).toContain("'x-cron-secret'");
    expect(migration).toContain("cron.schedule(\n    'sync-daily-devotion-video',\n    '10 23 * * *'");
  });
});

describe("sync-devotion-video edge function", () => {
  it("requires the shared cron secret header, matching the generate-daily-quizzes auth pattern", () => {
    expect(fn).toContain('Deno.env.get("DEVOTION_VIDEO_SYNC_CRON_SECRET")');
    expect(fn).toContain('req.headers.get("x-cron-secret") !== cronSecret');
    expect(fn).toContain('return respond({ error: "unauthorized", invocationId }, 401)');
  });

  it("only looks at active devotional plans for today (Asia/Taipei), and exits cleanly when there is none", () => {
    expect(fn).toContain('.eq("plan_kind", "devotional")');
    expect(fn).toContain('.lte("start_date", today).gte("end_date", today)');
    expect(fn).toContain('status: "no_active_devotional_plan"');
  });

  it("resolves the channel's id from its @handle without any login, and allows skipping that step via env override", () => {
    const idx = fn.indexOf("async function resolveChannelId(handle: string)");
    expect(idx).toBeGreaterThan(-1);
    const body = fn.slice(idx, idx + 700);
    expect(body).toContain("https://www.youtube.com/@${handle}");
    expect(body).toContain('"channelId":"(UC[0-9A-Za-z_-]{22})"');
    expect(fn).toContain('Deno.env.get("DEVOTION_YOUTUBE_CHANNEL_ID")');
  });

  it("reads the channel's public RSS feed (no auth, no API key, no quota) as the fallback for the latest video", () => {
    const idx = fn.indexOf("async function fetchLatestVideo(channelId: string)");
    expect(idx).toBeGreaterThan(-1);
    const body = fn.slice(idx, idx + 700);
    expect(body).toContain("https://www.youtube.com/feeds/videos.xml?channel_id=${channelId}");
    // 欄位解析抽成共用的 parseFeedEntry（頻道與播放清單都用同一份）
    const pIdx = fn.indexOf("function parseFeedEntry(entry: string)");
    expect(pIdx).toBeGreaterThan(-1);
    const pBody = fn.slice(pIdx, pIdx + 500);
    expect(pBody).toContain("<yt:videoId>([^<]+)<\\/yt:videoId>");
    expect(pBody).toContain("<published>([^<]+)<\\/published>");
  });

  it("prefers the devotional playlist (only devotional videos) over the whole channel, and matches by today's date", () => {
    // 播放清單 ID 從計畫的 rules.devotionPlaylistId 來（migration 0157），
    // 也接受 DEVOTION_YOUTUBE_PLAYLIST_ID 環境變數當退路。
    expect(fn).toContain('.select("id, name, start_date, end_date, rules")');
    expect(fn).toContain("planRules.devotionPlaylistId");
    expect(fn).toContain('Deno.env.get("DEVOTION_YOUTUBE_PLAYLIST_ID")');
    const idx = fn.indexOf("async function fetchPlaylistVideoForDate(");
    expect(idx).toBeGreaterThan(-1);
    const body = fn.slice(idx, idx + 700);
    expect(body).toContain("https://www.youtube.com/feeds/videos.xml?playlist_id=${playlistId}");
    // 掃過所有 <entry>，不是只看第一則
    expect(body).toContain("/<entry>([\\s\\S]*?)<\\/entry>/g");
    expect(body).toContain("parsed.publishedTaipeiDate === targetTaipeiDate");
  });

  it("skips instead of backfilling when there is no video for today (playlist miss, or channel latest not from today)", () => {
    // 播放清單找不到今天那一支 -> picked 為 null；頻道退路仍守「發布日 = 今天」
    expect(fn).toContain("latest.publishedTaipeiDate === today ? latest : null");
    const idx = fn.indexOf("if (!picked)");
    expect(idx).toBeGreaterThan(-1);
    const body = fn.slice(idx, idx + 400);
    expect(body).toContain('status: "no_new_video_today"');
  });

  it("writes through the blank-only RPC, keyed by day_index derived from the plan's start_date", () => {
    const idx = fn.indexOf("for (const plan of plans)");
    expect(idx).toBeGreaterThan(-1);
    const body = fn.slice(idx);
    expect(body).toContain("dayDifference(today, String(plan.start_date)) + 1");
    expect(body).toContain('supabase.rpc("sync_devotion_day_video"');
    expect(body).toContain("p_video_url: videoUrl, p_video_title: picked.title");
  });
});

describe("supabase/functions/README.md documents the new function", () => {
  it("lists the required secrets and the Vault setup command", () => {
    expect(readme).toContain("sync-devotion-video");
    expect(readme).toContain("DEVOTION_VIDEO_SYNC_CRON_SECRET");
    expect(readme).toContain("devotion_video_sync_cron_secret");
  });
});
