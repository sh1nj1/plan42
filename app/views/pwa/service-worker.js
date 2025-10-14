// Handle background messages from Firebase Cloud Messaging
self.addEventListener('push', (event) => {
    console.log('notification, event=', JSON.stringify(event))
    if (!event.data) return

    let payload = {}
    try {
        payload = event.data.json()
    } catch (error) {
        console.error('notification payload parse error', error)
        return
    }

    const notification = payload.notification || {}
    if (!notification.title && !notification.body) return

    const { title, body } = notification
    const data = Object.assign({}, payload.data || {}, notification.data || {})
    const path = data.path || notification.click_action
    if (path) {
        data.path = path
    }

    const options = {
        body,
        data
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
  const data = event.notification.data || {}
  const path = data.path
  if (!path) {
    return
  }

  const targetUrl = (() => {
    try {
      return new URL(path, self.location.origin).href
    } catch (error) {
      console.error('invalid notification path', error)
      return null
    }
  })()

  if (!targetUrl) {
    return
  }

  event.waitUntil(
    clients.matchAll({ type: 'window', includeUncontrolled: true }).then((clientList) => {
      for (let i = 0; i < clientList.length; i++) {
        const client = clientList[i]
        const clientUrl = (() => {
          try {
            return new URL(client.url, self.location.origin).href
          } catch (error) {
            console.error('invalid client url', error)
            return null
          }
        })()
        if (clientUrl && clientUrl === targetUrl && 'focus' in client) {
          return client.focus()
        }
      }
      if (clients.openWindow) {
        return clients.openWindow(targetUrl)
      }
    })
  )
})
