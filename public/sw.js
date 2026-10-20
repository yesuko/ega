// Lets Money Plan install as an app and shows a friendly page when offline.
// Pages hold your money data, so they are never cached: only the offline
// page and what it needs.
var CACHE = 'money-plan-v1';
var OFFLINE = ['/offline.html', '/style.css', '/icon.svg'];

self.addEventListener('install', function (event) {
  event.waitUntil(caches.open(CACHE).then(function (cache) { return cache.addAll(OFFLINE); }));
  self.skipWaiting();
});

self.addEventListener('activate', function (event) {
  event.waitUntil(caches.keys().then(function (keys) {
    return Promise.all(keys.filter(function (key) { return key !== CACHE; }).map(function (key) { return caches.delete(key); }));
  }));
  self.clients.claim();
});

self.addEventListener('fetch', function (event) {
  if (event.request.mode !== 'navigate') return;
  event.respondWith(fetch(event.request).catch(function () { return caches.match('/offline.html'); }));
});
