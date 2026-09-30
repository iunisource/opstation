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

// Wait up to [ms] for an open Opstation tab to confirm it routed itself.
function waitForAck(channel, ms) {
  return new Promise(function (resolve) {
    var done = false;
    var t = setTimeout(function () { if (!done) { done = true; resolve(false); } }, ms);
    channel.onmessage = function (e) {
      if (!done && e.data === 'ack') { done = true; clearTimeout(t); resolve(true); }
    };
  });
}

self.addEventListener('notificationclick', function (event) {
  event.notification.close();
  const url = appUrl(event.notification.data && event.notification.data.url);
  const path = url.split('#')[1] || '/';

  event.waitUntil((async function () {
    const clientList = await self.clients.matchAll({ type: 'window', includeUncontrolled: true });
    let best = null;
    for (const c of clientList) {
      if (c.url && c.url.indexOf(self.location.origin) === 0) {
        if (!best || c.focused || c.visibilityState === 'visible') best = c;
      }
    }

    if (best) {
      try { if ('focus' in best) await best.focus(); } catch (e) {}
      const bc = ('BroadcastChannel' in self) ? new BroadcastChannel('opstation-push') : null;
      // 1) Tell that tab directly; 2) if it doesn't confirm, broadcast to every
      // Opstation tab; 3) if still nothing, open the exact screen in a new window.
      best.postMessage('opstation-open:' + path);
      if (bc) {
        if (await waitForAck(bc, 1500)) { bc.close(); return; }
        bc.postMessage('opstation-open:' + path);
        if (await waitForAck(bc, 1500)) { bc.close(); return; }
        bc.close();
      } else {
        return;
      }
      try { if ('navigate' in best) { await best.navigate(url); return; } } catch (e) {}
    }
    if (self.clients.openWindow) return self.clients.openWindow(url);
  })());
});

// Push services can rotate a subscription; when they do, this fires and the app
// should re-subscribe on next load (handled client-side).
self.addEventListener('pushsubscriptionchange', function (event) {
  // No-op here; the Flutter app re-subscribes when an admin next opens it.
});
