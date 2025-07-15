import { initializeApp } from "firebase/app"
import { getMessaging, getToken } from "firebase/messaging"

function registerDevice(token) {
  fetch('/devices', {
    method: 'POST',
    headers: {
      'Content-Type': 'application/json',
      'X-CSRF-Token': document.querySelector('meta[name=csrf-token]').content
    },
    body: JSON.stringify({
      device: {
        client_id: navigator.userAgent,
        device_type: 'web',
        app_id: 'com.vrerv.collavre.web',
        app_version: document.querySelector('meta[name=app-version]').content,
        fcm_token: token
      }
    })
  })
}

if ('serviceWorker' in navigator) {
  window.addEventListener('load', () => {
    navigator.serviceWorker
      .register('/service-worker.js')
      .then((registration) => {
        if (Notification.permission === 'default') {
          Notification.requestPermission()
        }

        const config = window.firebaseConfig
        if (!config) return

        const app = initializeApp(config)
        const messaging = getMessaging(app)

        getToken(messaging, { vapidKey: config.vapidKey, serviceWorkerRegistration: registration })
          .then((currentToken) => {
            if (currentToken) {
              registerDevice(currentToken)
            }
          })
          .catch((err) => console.error('Failed to get FCM token', err))
      })
      .catch((error) => {
        console.error('Service worker registration failed:', error)
      })
  })
}
