import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const jsonHeaders = { "Content-Type": "application/json" };

function respond(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), { status, headers: jsonHeaders });
}

function taipeiDate(date: Date = new Date()) {
  const parts = new Intl.DateTimeFormat("en-US", {
    timeZone: "Asia/Taipei", year: "numeric", month: "2-digit", day: "2-digit"
  }).formatToParts(date);
  const values = Object.fromEntries(parts.map(part => [part.type, part.value]));
  return `${values.year}-${values.month}-${values.day}`;
}

function utcDate(value: string) {
  const parsed = new Date(`${value}T00:00:00Z`);
  if (Number.isNaN(parsed.getTime())) throw new Error(`invalid_date:${value}`);
  return parsed;
}

function dayDifference(later: string, earlier: string) {
  return Math.floor((utcDate(later).getTime() - utcDate(earlier).getTime()) / 86400000);
}

function decodeXmlEntities(value: string) {
  return value
    .replace(/&lt;/g, "<").replace(/&gt;/g, ">")
    .replace(/&quot;/g, '"').replace(/&#39;/g, "'").replace(/&apos;/g, "'")
    .replace(/&amp;/g, "&");
}

// 頻道用 @handle 表示，但 YouTube 的公開 RSS 只吃 channel_id，所以先讀一次頻道
// 首頁解析出 channel_id——這一步跟用瀏覽器打開這個網址看到的是同一份公開網頁，
// 不需要登入、不使用任何帳號憑證。可用 DEVOTION_YOUTUBE_CHANNEL_ID 環境變數
// 直接指定 channel_id，跳過這個解析步驟（每次都少一次請求，也比較穩定）。
async function resolveChannelId(handle: string): Promise<string> {
  const response = await fetch(`https://www.youtube.com/@${handle}`, {
    headers: { "User-Agent": "Mozilla/5.0 (compatible; NewLifeBibleApp/1.0; +https://bible.newlife.org.tw)" }
  });
  if (!response.ok) throw new Error(`channel_page_fetch_failed:${response.status}`);
  const html = await response.text();
  const match = html.match(/"channelId":"(UC[0-9A-Za-z_-]{22})"/)
    || html.match(/<link rel="canonical" href="https:\/\/www\.youtube\.com\/channel\/(UC[0-9A-Za-z_-]{22})"/);
  if (!match) throw new Error("channel_id_not_found");
  return match[1];
}

type LatestVideo = { videoId: string; title: string; publishedTaipeiDate: string };

function parseFeedEntry(entry: string): LatestVideo | null {
  const videoId = entry.match(/<yt:videoId>([^<]+)<\/yt:videoId>/)?.[1];
  const titleRaw = entry.match(/<title>([\s\S]*?)<\/title>/)?.[1];
  const published = entry.match(/<published>([^<]+)<\/published>/)?.[1];
  if (!videoId || !titleRaw || !published) return null;
  const publishedDate = new Date(published);
  if (Number.isNaN(publishedDate.getTime())) return null;
  return {
    videoId,
    title: decodeXmlEntities(titleRaw.trim()),
    publishedTaipeiDate: taipeiDate(publishedDate)
  };
}

// YouTube 官方公開的頻道 RSS（Atom）訂閱源，任何 RSS 閱讀器都能讀，不需要
// 登入、不需要申請 API 金鑰、沒有配額限制。只看第一則（= 最新一支影片）。
// 只在沒有設定靈修播放清單時才會用到——讀整個頻道有抓到非靈修影片的風險。
async function fetchLatestVideo(channelId: string): Promise<LatestVideo | null> {
  const response = await fetch(`https://www.youtube.com/feeds/videos.xml?channel_id=${channelId}`);
  if (!response.ok) throw new Error(`feed_fetch_failed:${response.status}`);
  const xml = await response.text();
  const entryMatch = xml.match(/<entry>([\s\S]*?)<\/entry>/);
  if (!entryMatch) return null;
  return parseFeedEntry(entryMatch[1]);
}

// 靈修播放清單的公開 RSS：清單裡只有靈修影片，所以可以安全地「抓當天那一支」，
// 不會像讀整個頻道那樣抓到主日信息 / 活動預告 / 見證等其他影片。掃過全部項目
// （不只第一則，避免播放清單排序方式影響），找發布日 = 今天（Asia/Taipei）
// 的那一支；找不到就回 null（留白讓管理員手動補，或稍晚 cron 再跑時再試）。
async function fetchPlaylistVideoForDate(
  playlistId: string, targetTaipeiDate: string
): Promise<LatestVideo | null> {
  const response = await fetch(`https://www.youtube.com/feeds/videos.xml?playlist_id=${playlistId}`);
  if (!response.ok) throw new Error(`playlist_feed_fetch_failed:${response.status}`);
  const xml = await response.text();
  const entryRegex = /<entry>([\s\S]*?)<\/entry>/g;
  let match: RegExpExecArray | null;
  while ((match = entryRegex.exec(xml)) !== null) {
    const parsed = parseFeedEntry(match[1]);
    if (parsed && parsed.publishedTaipeiDate === targetTaipeiDate) return parsed;
  }
  return null;
}

Deno.serve(async req => {
  const invocationId = crypto.randomUUID();
  console.info("devotion_video_sync_invocation_received", JSON.stringify({ invocationId, method: req.method, hasCronSecret: Boolean(req.headers.get("x-cron-secret")) }));
  if (req.method !== "POST") {
    console.warn("devotion_video_sync_method_rejected", JSON.stringify({ invocationId, method: req.method }));
    return respond({ error: "method_not_allowed", invocationId }, 405);
  }
  const cronSecret = Deno.env.get("DEVOTION_VIDEO_SYNC_CRON_SECRET") || "";
  if (!cronSecret || req.headers.get("x-cron-secret") !== cronSecret) {
    console.warn("devotion_video_sync_auth_rejected", JSON.stringify({ invocationId, secretConfigured: Boolean(cronSecret) }));
    return respond({ error: "unauthorized", invocationId }, 401);
  }

  const supabaseUrl = Deno.env.get("SUPABASE_URL") || "";
  const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") || "";
  const configuredChannelId = (Deno.env.get("DEVOTION_YOUTUBE_CHANNEL_ID") || "").trim();
  const configuredPlaylistId = (Deno.env.get("DEVOTION_YOUTUBE_PLAYLIST_ID") || "").trim();
  const handle = (Deno.env.get("DEVOTION_YOUTUBE_HANDLE") || "NewLifeChurch").trim().replace(/^@/, "");
  if (!supabaseUrl || !serviceRoleKey) {
    console.error("devotion_video_sync_server_not_configured", JSON.stringify({ invocationId }));
    return respond({ error: "server_not_configured", invocationId }, 500);
  }

  const body = await req.json().catch(() => ({}));
  const today = /^\d{4}-\d{2}-\d{2}$/.test(String(body?.date || "")) ? String(body.date) : taipeiDate();
  console.info("devotion_video_sync_started", JSON.stringify({ invocationId, source: String(body?.source || "unknown"), today }));

  const supabase = createClient(supabaseUrl, serviceRoleKey, { auth: { persistSession: false, autoRefreshToken: false } });

  const { data: plans, error: planError } = await supabase.from("global_plans")
    .select("id, name, start_date, end_date, rules")
    .eq("plan_kind", "devotional")
    .lte("start_date", today).gte("end_date", today);
  if (planError) {
    console.error("devotion_video_sync_plan_lookup_failed", JSON.stringify({ invocationId, error: planError.message }));
    return respond({ error: planError.message, invocationId }, 500);
  }
  if (!plans || plans.length === 0) {
    console.info("devotion_video_sync_no_active_plan", JSON.stringify({ invocationId, today }));
    return respond({ date: today, status: "no_active_devotional_plan", updated: 0, invocationId });
  }

  // 頻道整體「最新一支」只在某個計畫沒有綁定播放清單時才需要，且只抓一次。
  let channelId = configuredChannelId;
  let channelLatest: LatestVideo | null | undefined;
  const resolveChannelLatest = async (): Promise<LatestVideo | null> => {
    if (channelLatest !== undefined) return channelLatest;
    if (!channelId) channelId = await resolveChannelId(handle);
    channelLatest = await fetchLatestVideo(channelId);
    return channelLatest;
  };

  const results: Array<Record<string, unknown>> = [];
  let updated = 0;
  for (const plan of plans) {
    const dayIndex = dayDifference(today, String(plan.start_date)) + 1;
    if (dayIndex < 1) { results.push({ planId: plan.id, status: "before_plan_start" }); continue; }

    const planRules = (plan.rules && typeof plan.rules === "object") ? plan.rules as Record<string, unknown> : {};
    const playlistId = String(planRules.devotionPlaylistId || "").trim() || configuredPlaylistId;

    // 優先讀計畫綁定的靈修播放清單（只含靈修影片）；沒有才退回讀整個頻道的
    // 最新一支——後者仍守「發布日必須是今天」，避免把非今天的舊片誤植。
    let picked: LatestVideo | null = null;
    const feedSource = playlistId ? `playlist:${playlistId}` : "channel";
    try {
      if (playlistId) {
        picked = await fetchPlaylistVideoForDate(playlistId, today);
      } else {
        const latest = await resolveChannelLatest();
        picked = latest && latest.publishedTaipeiDate === today ? latest : null;
      }
    } catch (error) {
      const message = String((error as Error)?.message || error);
      console.error("devotion_video_sync_feed_fetch_failed", JSON.stringify({ invocationId, planId: plan.id, feedSource, error: message }));
      results.push({ planId: plan.id, dayIndex, status: "failed", error: message, feedSource });
      continue;
    }

    if (!picked) {
      // 今天還沒有對應影片（例如上架時間延後）：寧可留白讓管理員之後手動補，
      // 也不要把不是今天的影片誤植到今天的靈修內容。
      console.info("devotion_video_sync_no_new_video_today", JSON.stringify({ invocationId, planId: plan.id, today, feedSource }));
      results.push({ planId: plan.id, dayIndex, status: "no_new_video_today", feedSource });
      continue;
    }

    const videoUrl = `https://www.youtube.com/watch?v=${picked.videoId}`;
    const { data: syncResult, error: syncError } = await supabase.rpc("sync_devotion_day_video", {
      p_global_plan_id: plan.id, p_day_index: dayIndex,
      p_video_url: videoUrl, p_video_title: picked.title
    });
    if (syncError) {
      console.error("devotion_video_sync_rpc_failed", JSON.stringify({ invocationId, planId: plan.id, dayIndex, error: syncError.message }));
      results.push({ planId: plan.id, dayIndex, status: "failed", error: syncError.message });
      continue;
    }
    if (syncResult?.updated) updated += 1;
    results.push({
      planId: plan.id, dayIndex, feedSource, videoId: picked.videoId,
      status: syncResult?.updated ? "updated" : "already_set_or_missing_day"
    });
  }

  console.info("devotion_video_sync_finished", JSON.stringify({ invocationId, today, updated, results }));
  return respond({ date: today, updated, results, invocationId });
});
