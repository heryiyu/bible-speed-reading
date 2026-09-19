// @vitest-environment jsdom

import { describe, it, expect, beforeEach, vi } from "vitest";
import { PwaCoordinator } from "./PwaCoordinator.js";
import { OfflineQueueRepository } from "./OfflineQueueRepository.js";
import { OfflineSyncManager } from "./OfflineSyncManager.js";

// 只測「小測驗逐題送出/結算」這條離線佇列路徑，不跑 initialize()（那會牽動
// Service Worker 註冊等一大票跟這裡無關的東西）。db.submitDailyQuizAnswer /
// finalizeDailyQuizAttempt（_callQuizRpc）的真實行為是「從不 throw，失敗
// 一律回傳 {success:false,...}」——這裡驗證的正是 PwaCoordinator 有沒有正確
// 檢查回傳值，而不是誤用 try/catch 去抓一個永遠不會被丟出來的例外。

class MemoryDb {
  constructor() { this.records = new Map(); }
  async getAll() { return [...this.records.values()]; }
  async put(_store, value) { this.records.set(value.id, structuredClone(value)); return value.id; }
  async delete(_store, id) { this.records.delete(id); }
}

function makeCoordinator() {
  const coordinator = new PwaCoordinator();
  // PwaCoordinator's constructor already built this.queueRepository against the
  // real IndexedDbClient; swap both dbClient AND queueRepository for the fake,
  // otherwise the repository below would still point at the real (jsdom-less) one.
  coordinator.dbClient = new MemoryDb();
  coordinator.queueRepository = new OfflineQueueRepository(coordinator.dbClient);
  coordinator.syncManager = new OfflineSyncManager({
    queueRepository: coordinator.queueRepository,
    handlers: {
      SUBMIT_DAILY_QUIZ_ANSWER: payload => coordinator.syncQuizAnswerOperation(payload),
      FINALIZE_DAILY_QUIZ_ATTEMPT: payload => coordinator.syncQuizFinalizeOperation(payload)
    }
  });
  return coordinator;
}

beforeEach(() => {
  window.state = { isSupabaseMode: true, supabase: {}, currentProfileId: "user-1" };
});

describe("PwaCoordinator: quiz answer offline queue", () => {
  it("queues instead of calling through when navigator.onLine is false", async () => {
    const coordinator = makeCoordinator();
    const submitDailyQuizAnswer = vi.fn();
    window.db = { submitDailyQuizAnswer };
    coordinator.installQuizAnswerQueue();

    vi.spyOn(navigator, "onLine", "get").mockReturnValue(false);
    const result = await window.db.submitDailyQuizAnswer("pub-1", "q1", 2, 5);

    expect(result).toEqual({ success: true, queued: true, offline: true });
    expect(submitDailyQuizAnswer).not.toHaveBeenCalled();
    expect(await coordinator.queueRepository.countPending()).toBe(1);
  });

  it("queues when the underlying call fails with a network-shaped error, even while nominally online", async () => {
    const coordinator = makeCoordinator();
    const networkError = Object.assign(new Error("Failed to fetch"), {});
    const submitDailyQuizAnswer = vi.fn(async () => ({ success: false, error: networkError, message: "network" }));
    window.db = { submitDailyQuizAnswer };
    coordinator.installQuizAnswerQueue();

    vi.spyOn(navigator, "onLine", "get").mockReturnValue(true);
    const result = await window.db.submitDailyQuizAnswer("pub-1", "q1", 2, 5);

    expect(result).toEqual({ success: true, queued: true, offline: true });
    expect(await coordinator.queueRepository.countPending()).toBe(1);
  });

  it("does NOT queue a genuine validation failure (not a network problem) and returns it as-is", async () => {
    const coordinator = makeCoordinator();
    const validationError = Object.assign(new Error("quiz_already_submitted"), { status: 400, code: "P0001" });
    const submitDailyQuizAnswer = vi.fn(async () => ({ success: false, error: validationError, message: "這份小測驗已經送出過了。" }));
    window.db = { submitDailyQuizAnswer };
    coordinator.installQuizAnswerQueue();

    vi.spyOn(navigator, "onLine", "get").mockReturnValue(true);
    const result = await window.db.submitDailyQuizAnswer("pub-1", "q1", 2, 5);

    expect(result.success).toBe(false);
    expect(result.message).toBe("這份小測驗已經送出過了。");
    expect(await coordinator.queueRepository.countPending()).toBe(0);
  });

  it("resubmitting the same question replaces the queued entry instead of duplicating it", async () => {
    const coordinator = makeCoordinator();
    window.db = { submitDailyQuizAnswer: vi.fn() };
    coordinator.installQuizAnswerQueue();
    vi.spyOn(navigator, "onLine", "get").mockReturnValue(false);

    await window.db.submitDailyQuizAnswer("pub-1", "q1", 0, 3);
    await window.db.submitDailyQuizAnswer("pub-1", "q1", 2, 7);

    const pending = await coordinator.queueRepository.getPending();
    expect(pending).toHaveLength(1);
    expect(pending[0].payload.response).toBe(2);
    expect(pending[0].payload.timeSpentSeconds).toBe(7);
  });

  it("flushing a queued answer calls the original (unwrapped) RPC and removes it from the queue on success", async () => {
    const coordinator = makeCoordinator();
    const originalSubmit = vi.fn(async () => ({ success: true, data: { correct: true } }));
    window.db = { submitDailyQuizAnswer: originalSubmit };
    coordinator.installQuizAnswerQueue();

    vi.spyOn(navigator, "onLine", "get").mockReturnValue(false);
    await window.db.submitDailyQuizAnswer("pub-1", "q1", 1, 4);

    vi.spyOn(navigator, "onLine", "get").mockReturnValue(true);
    await coordinator.syncManager.syncPending();

    expect(originalSubmit).toHaveBeenCalledWith("pub-1", "q1", 1, 4);
    expect(await coordinator.queueRepository.countPending()).toBe(0);
  });
});

describe("PwaCoordinator: quiz finalize offline queue", () => {
  it("queues finalize when offline and flushes it after reconnecting", async () => {
    const coordinator = makeCoordinator();
    const originalFinalize = vi.fn(async () => ({ success: true, data: { score: 4, total: 5 } }));
    window.db = { finalizeDailyQuizAttempt: originalFinalize };
    coordinator.installQuizFinalizeQueue();

    vi.spyOn(navigator, "onLine", "get").mockReturnValue(false);
    const queuedResult = await window.db.finalizeDailyQuizAttempt("pub-1");
    expect(queuedResult).toEqual({ success: true, queued: true, offline: true });
    expect(originalFinalize).not.toHaveBeenCalled();

    vi.spyOn(navigator, "onLine", "get").mockReturnValue(true);
    await coordinator.syncManager.syncPending();
    expect(originalFinalize).toHaveBeenCalledWith("pub-1");
    expect(await coordinator.queueRepository.countPending()).toBe(0);
  });
});
