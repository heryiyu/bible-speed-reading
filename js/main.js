// Application entry point & initialization bootstrap

document.addEventListener("DOMContentLoaded", async () => {
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

  // 6.5 Load Church Organization Structure
  try {
    await db.loadOrgStructure();
  } catch (err) {
    console.error("Failed to load church organization structure:", err);
  }

  // 7. Load Data & Render initial Dashboard
  try {
    await db.loadUserData();
    updateDashboardView();
  } catch (err) {
    console.error("Failed to load user data & render initial dashboard:", err);
  }

  // 8. Register Service Worker for PWA offline support
  if ("serviceWorker" in navigator) {
    try {
      navigator.serviceWorker.register("./sw.js")
        .then(reg => console.log("Service Worker 註冊成功，範圍:", reg.scope))
        .catch(err => console.error("Service Worker 註冊失敗:", err));
    } catch (err) {
      console.error("Service Worker registration failed:", err);
    }
  }

  // 9. Final Auth Verification check (handles race conditions during asynchronous token recovery)
  try {
    if (state.isSupabaseMode && state.supabase) {
      setTimeout(async () => {
        const { data: { session } } = await state.supabase.auth.getSession();
        if (session) {
          console.log("Auth session recovered in delayed check:", session);
          db.updateAuthUI(session);
          await db.loadUserData();
          updateDashboardView();
        }
      }, 500); // 500ms delay to allow async Supabase session recovery to complete
    }
  } catch (err) {
    console.error("Failed in final auth verification check:", err);
  }
});
