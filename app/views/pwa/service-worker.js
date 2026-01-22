// Handle background messages from Firebase Cloud Messaging
self.addEventListener('push', (event) => {
    console.log('notification, event=', JSON.stringify(event))
    // if (!event.data) return
    const payload = event.data.json()
    if (!payload.notification) return
    const {title, body} = payload.notification

    const options = {
        body,
        data: payload.notification.data || {
            path: payload.notification.click_action
        }
    }
    event.waitUntil(
        self.registration.showNotification(title, options).then(() => {
            console.log('notification showed')
        }).catch((error) => {
            console.error('notification error', error)
        })
    )
})

self.addEventListener('notificationclick', function(event) {
  console.log('notificationclick, event=', JSON.stringify(event))
  event.notification.close()
  const path = event.notification.data.path
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
