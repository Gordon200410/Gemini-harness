// 只快取網頁本身與 cdnjs 的函式庫，加快開啟速度；呼叫 Gemini / Vertex 的請求一律不碰。
const CACHE = 'gemini-harness-v1';
self.addEventListener('install', e => { self.skipWaiting(); });
self.addEventListener('activate', e => {
  e.waitUntil(caches.keys().then(ks => Promise.all(ks.filter(k => k !== CACHE).map(k => caches.delete(k)))).then(() => self.clients.claim()));
});
self.addEventListener('fetch', e => {
  const req = e.request;
  if (req.method !== 'GET') return;
  const url = new URL(req.url);
  if (url.hostname === 'cdnjs.cloudflare.com') {
    // 版本固定的函式庫：先用快取，沒有才下載
    e.respondWith(caches.open(CACHE).then(c => c.match(req).then(hit => hit || fetch(req).then(r => { if (r.ok || r.type === 'opaque') c.put(req, r.clone()); return r; }))));
    return;
  }
  if (url.origin === self.location.origin) {
    // 自己的檔案：先抓最新版，離線或失敗時才用快取，所以更新後重新整理就會生效
    e.respondWith(fetch(req).then(r => { if (r.ok) { const cp = r.clone(); caches.open(CACHE).then(c => c.put(req, cp)); } return r; }).catch(() => caches.match(req)));
  }
});
