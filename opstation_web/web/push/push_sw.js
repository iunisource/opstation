// Opstation push service worker.
// Handles incoming Web Push messages and notification clicks.
// Deployed at the web root and registered from index.html (see integration notes).

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
    data: { url: data.url || '/' },      // where a click should take the user
    requireInteraction: false,
  };

  event.waitUntil(self.registration.showNotification(title, options));
});

self.addEventListener('notificationclick', function (event) {
  event.notification.close();
  const target = (event.notification.data && event.notification.data.url) || '/';

  event.waitUntil(
    self.clients.matchAll({ type: 'window', includeUncontrolled: true }).then(function (clientList) {
      // Focus an already-open Opstation tab and route it, else open a new one.
      for (const client of clientList) {
        if ('focus' in client) {
          client.focus();
          if ('navigate' in client) {
            try { client.navigate(target); } catch (e) {}
          }
          return;
        }
      }
      if (self.clients.openWindow) return self.clients.openWindow(target);
    })
  );
});

// Push services can rotate a subscription; when they do, this fires and the app
// should re-subscribe on next load (handled client-side).
self.addEventListener('pushsubscriptionchange', function (event) {
  // No-op here; the Flutter app re-subscribes when an admin next opens it.
});
