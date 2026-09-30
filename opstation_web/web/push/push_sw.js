// Opstation push service worker.
// Handles incoming Web Push messages and notification clicks.
// Registered from index.html.

// Take over straight away when a new version is deployed (no waiting for
// every tab to close), so notification clicks always use the latest logic.
self.addEventListener('install', function () { self.skipWaiting(); });
self.addEventListener('activate', function (event) { event.waitUntil(self.clients.claim()); });

// Turn whatever the server sent ("/hr/leave?focus=lv_1", "/#/...", a full URL)
// into a full app address. The app uses hash routing, so screens live after
// "/#" — "/hr/leave" on its own would land on the dashboard.
function appUrl(u) {
  var origin = self.location.origin;
  if (!u) return origin + '/#/';
  if (/^https?:\/\//i.test(u)) return u;
  if (u.indexOf('/#') === 0) return origin + u;
  if (u.indexOf('#') === 0) return origin + '/' + u;
  return origin + '/#' + (u.charAt(0) === '/' ? u : '/' + u);
}

self.addEventListener('push', function (event) {
  let data = {};
  try {
    data = event.data ? event.data.json() : {};
  } catch (e) {
    data = { title: 'Opstation', body: event.data ? event.data.text() : '' };
  }

  const title = data.title || 'Opstation';
  const options = {
    body: data.body || '',
    icon: data.icon || '/icons/Icon-192.png',
    badge: data.badge || '/icons/Icon-192.png',
    tag: data.tag,                       // collapses duplicates for the same voucher
    renotify: !!data.tag,
    data: { url: appUrl(data.url || '/') },  // where a click should take the user
    requireInteraction: false,
  };

  event.waitUntil(self.registration.showNotification(title, options));
});

// Leave the destination where the app can always find it (Cache Storage is
// shared by every Opstation page, whatever service worker controls it). The
// app picks it up the moment it is focused / becomes visible, so a tap works
// even when the page can't receive messages from this worker (e.g. iPhone).
function rememberTarget(path) {
  if (!self.caches) return Promise.resolve();
  return caches.open('opstation-push').then(function (c) {
    return c.put('/__pending_open', new Response(JSON.stringify({ path: path, t: Date.now() }),
      { headers: { 'Content-Type': 'application/json' } }));
  }).catch(function () {});
}

self.addEventListener('notificationclick', function (event) {
  event.notification.close();
  const url = appUrl(event.notification.data && event.notification.data.url);
  const path = url.split('#')[1] || '/';

  event.waitUntil((async function () {
    // Bring Opstation forward FIRST (browsers only allow this right after the
    // tap), then tell it where to go.
    let clientList = [];
    try { clientList = await self.clients.matchAll({ type: 'window', includeUncontrolled: true }); } catch (e) {}
    let best = null;
    for (const c of clientList) {
      if (c.url && c.url.indexOf(self.location.origin) === 0) {
        if (!best || c.focused || c.visibilityState === 'visible') best = c;
      }
    }

    let focused = false;
    if (best && 'focus' in best) {
      try { await best.focus(); focused = true; } catch (e) { focused = false; }
    }

    if (!focused) {
      // No open window (or it can't be focused): open the exact screen.
      try { if (self.clients.openWindow) { await self.clients.openWindow(url); return; } } catch (e) {}
    }

    // An Opstation window is in front: route it to the document.
    await rememberTarget(path);
    try { best && best.postMessage('opstation-open:' + path); } catch (e) {}
    try {
      if ('BroadcastChannel' in self) {
        const bc = new BroadcastChannel('opstation-push');
        bc.postMessage('opstation-open:' + path);
        bc.close();
      }
    } catch (e) {}
  })());
});

// Push services can rotate a subscription; when they do, this fires and the app
// should re-subscribe on next load (handled client-side).
self.addEventListener('pushsubscriptionchange', function (event) {
  // No-op here; the Flutter app re-subscribes when an admin next opens it.
});
