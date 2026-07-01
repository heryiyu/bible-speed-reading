// Application entry point & initialization bootstrap

document.addEventListener("DOMContentLoaded", async () => {
  // 💡 體驗優化：在最開始立即顯示 Loading 載入畫面，防止使用者在資料加載前看到 Demo 畫面或舊資料
  if (typeof loader !== "undefined" && loader.show) {
    loader.show("系統安全載入中，請稍候...");
  }

  // 1. Initialize Theme
  try {
    initTheme();
  } catch (err) {
    console.error("Failed to initialize theme:", err);
  }
  
  // 2. Initialize Routing
  try {
    appRouter.init();
  } catch (err) {
    console.error("Failed to initialize routing:", err);
  }

  // 3. Initialize Settings & State Loading
  try {
    loadLocalSettings();
  } catch (err) {
    console.error("Failed to load local settings:", err);
  }
  
  // 4. Initialize Database Connection & Auth (triggers loadUserData)
  try {
    await db.init();
  } catch (err) {
    console.error("Failed to initialize database connection & auth:", err);
  }

  // 5. Initialize Bible Reader Controls & Selectors
  try {
    initReaderControls();
  } catch (err) {
    console.error("Failed to initialize Bible reader controls:", err);
  }

  // 6. Initialize Plan Creation Form & Checkboxes
  try {
    initPlanControls();
  } catch (err) {
    console.error("Failed to initialize plan controls:", err);
  }

  // 6.2 Initialize Devotional Notes Controls
  try {
    initDevotionalControls();
  } catch (err) {
    console.error("Failed to initialize devotional controls:", err);
  }

  // 6.3 Initialize Profile & Auth Controls
  try {
    initProfileControls();
  } catch (err) {
    console.error("Failed to initialize profile/auth controls:", err);
  }

  // 6.5 & 7. Load Data in Parallel, Verify Session & Render initial Dashboard
  try {
    // 💡 體驗優化：平行載入組織結構與用戶資料，顯著縮短冷啟動等待時間
    await Promise.all([
      db.loadOrgStructure(),
      db.loadUserData()
    ]);

    // 💡 最終會話校驗：確保非同步 token 恢復完成（防制多重連線邊際狀況）
    if (state.isSupabaseMode && state.supabase) {
      const { data: { session } } = await state.supabase.auth.getSession();
      if (session) {
        db.updateAuthUI(session);
        await db.loadUserData();
      }
    }

    // 渲染初始儀表板
    updateDashboardView();
  } catch (err) {
    console.error("Failed to load initial data & render dashboard:", err);
  } finally {
    // 💡 體驗最優化：保證所有資料載入與畫面渲染「完全就緒」後才隱藏 Loading，不讓使用者看見空白或 Demo 畫面
    if (typeof loader !== "undefined" && loader.hide) {
      loader.hide();
    }
  }

  // 8. Register Service Worker for PWA offline support
  const isLocalhost = window.location.hostname === 'localhost' || 
                      window.location.hostname === '127.0.0.1' || 
                      window.location.hostname.startsWith('10.') || 
                      window.location.hostname.startsWith('192.168.');

  if ("serviceWorker" in navigator) {
    if (isLocalhost) {
      navigator.serviceWorker.getRegistrations().then(registrations => {
        for (let registration of registrations) {
          registration.unregister().then(success => {
            if (success) {
              console.log("Localhost detected: Unregistered existing Service Worker.");
            }
          });
        }
      });
    } else {
      try {
        navigator.serviceWorker.register("./sw.js")
          .then(reg => console.log("Service Worker 註冊成功，範圍:", reg.scope))
          .catch(err => console.error("Service Worker 註冊失敗:", err));
      } catch (err) {
        console.error("Service Worker registration failed:", err);
      }
    }
  }
});
