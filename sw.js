// Service Worker Cache Buster
// 💡 徹底註銷 Service Worker 並清空 Cache Storage，解決手機端快取鎖死舊版 plan.js 的問題
self.addEventListener('install', (e) => {
  self.skipWaiting();
});

self.addEventListener('activate', (e) => {
  e.waitUntil(
    caches.keys().then((keys) => {
      return Promise.all(keys.map(key => caches.delete(key)));
    }).then(() => {
      console.log('[Service Worker Cache Buster] Caches cleared successfully.');
      return self.registration.unregister();
    }).then(() => {
      console.log('[Service Worker Cache Buster] Service Worker unregistered.');
      return self.clients.matchAll();
    }).then((clients) => {
      clients.forEach(client => {
        if (client.url) {
          client.navigate(client.url);
        }
      });
    })
  );
});
