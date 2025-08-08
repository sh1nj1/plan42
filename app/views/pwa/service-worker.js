// Handle background messages from Firebase Cloud Messaging
self.addEventListener('push', async (event) => {
  if (!event.data) return
  const payload = await event.data.json()
  if (!payload.notification) return
  const { title, body } = payload.notification
  event.waitUntil(
    self.registration.showNotification(title, {
      body,
      data: payload.data || {}
    })
  )
})

self.addEventListener('notificationclick', function(event) {
  event.notification.close()
  const path = event.notification.data.path
  if (!path) return
  event.waitUntil(
    clients.matchAll({ type: 'window' }).then((clientList) => {
      for (let i = 0; i < clientList.length; i++) {
        const client = clientList[i]
        const clientPath = new URL(client.url).pathname
        if (clientPath === path && 'focus' in client) {
          return client.focus()
        }
      }
      if (clients.openWindow) {
        return clients.openWindow(path)
      }
    })
  )
})
