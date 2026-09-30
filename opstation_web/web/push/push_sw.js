// Opstation push service worker.
// Handles incoming Web Push messages and notification clicks.
// Deployed at the web root and registered from index.html (see integration notes).

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

self.addEventListener('notificationclick', function (event) {
  event.notification.close();
  const url = appUrl(event.notification.data && event.notification.data.url);
  const path = url.split('#')[1] || '/';

  event.waitUntil(
    self.clients.matchAll({ type: 'window', includeUncontrolled: true }).then(function (clientList) {
      // An Opstation tab is already open: bring it forward and tell the app
      // which screen / document to open (the app routes itself — no reload).
      let best = null;
      for (const c of clientList) {
        if (c.url && c.url.indexOf(self.location.origin) === 0) {
          if (!best || c.focused || c.visibilityState === 'visible') best = c;
        }
      }
      if (best) {
        best.postMessage('opstation-open:' + path);
        if ('focus' in best) return best.focus();
        return;
      }
      // Nothing open: open the exact screen in a new window.
      if (self.clients.openWindow) return self.clients.openWindow(url);
    })
  );
});

// Push services can rotate a subscription; when they do, this fires and the app
// should re-subscribe on next load (handled client-side).
self.addEventListener('pushsubscriptionchange', function (event) {
  // No-op here; the Flutter app re-subscribes when an admin next opens it.
});
