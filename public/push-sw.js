/* Web Push handlers — imported into the generated Workbox service worker
   via vite-plugin-pwa `workbox.importScripts`. Plain JS on purpose: this
   file is served as-is, it is never bundled. */

self.addEventListener('push', (event) => {
  if (!event.data) return
  let d = {}
  try {
    d = event.data.json()
  } catch {
    d = { title: 'Otopark', body: event.data.text() }
  }
  event.waitUntil(
    self.registration.showNotification(d.title || 'Otopark', {
      body: d.body || '',
      icon: '/Otopark/icons/icon-192.png',
      badge: '/Otopark/icons/icon-192.png',
      // Collapse repeats of the same kind rather than stacking them up.
      tag: d.tag || undefined,
      data: { link: d.link || '/' },
    }),
  )
})

self.addEventListener('notificationclick', (event) => {
  event.notification.close()
  const link = (event.notification.data && event.notification.data.link) || '/'
  const url = '/Otopark' + link
  event.waitUntil(
    clients.matchAll({ type: 'window', includeUncontrolled: true }).then((list) => {
      for (const c of list) {
        if ('focus' in c) {
          c.navigate(url)
          return c.focus()
        }
      }
      return clients.openWindow(url)
    }),
  )
})
