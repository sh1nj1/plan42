import {initializeApp} from "firebase/app"
import {getMessaging, getToken, isSupported} from "firebase/messaging"

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

function updatePreference(enabled) {
  fetch('/users/notification_settings', {
    method: 'PATCH',
    headers: {
      'Content-Type': 'application/json',
      'X-CSRF-Token': document.querySelector('meta[name=csrf-token]').content
    },
    body: JSON.stringify({ user: { notifications_enabled: enabled } })
  })
}

function initMessaging(registration) {
  if (!isSupported()) {
    console.warn('Notifications not supported')
    return
  }
  const config = window.firebaseConfig
  if (!config) {
    console.warn('No firebase config found')
    return
  }
  const app = initializeApp(config)
  const messaging = getMessaging(app)
  getToken(messaging, { vapidKey: config.vapidKey, serviceWorkerRegistration: registration })
    .then((currentToken) => {
      if (currentToken) {
          if (localStorage.getItem('fcm_token') === currentToken) {
              // ok
          } else {
              registerDevice(currentToken)
              localStorage.setItem('fcm_token', currentToken)
          }
      }
    })
    .catch((err) => console.error('Failed to get FCM token', err))
}

function showPermissionPrompt(registration) {
  const modal = document.getElementById('notification-permission-modal')
  if (!modal) {
    Notification.requestPermission().then((permission) => {
      updatePreference(permission === 'granted')
      if (permission === 'granted') {
        initMessaging(registration)
      }
    })
    return
  }
  modal.style.display = 'flex'
  document.body.classList.add('no-scroll')
  const allowBtn = document.getElementById('allow-notifications')
  const denyBtn = document.getElementById('deny-notifications')

  allowBtn.onclick = () => {
    modal.style.display = 'none'
    document.body.classList.remove('no-scroll')
    Notification.requestPermission().then((permission) => {
      updatePreference(permission === 'granted')
      if (permission === 'granted') {
        initMessaging(registration)
      }
    })
  }

  denyBtn.onclick = () => {
    const confirmText = denyBtn.dataset.confirmMessage
    if (confirm(confirmText)) {
      modal.style.display = 'none'
      document.body.classList.remove('no-scroll')
      updatePreference(false)
    }
  }
}

if ('serviceWorker' in navigator) {
  window.addEventListener('turbo:load', () => {
    navigator.serviceWorker
      .register('/service-worker.js', { updateViaCache: 'none'})
      .then((registration) => {
        const meta = document.querySelector('meta[name=notifications-enabled]')
        if (!meta) {
          return
        }
        const pref = meta.content

        if (pref === 'false') {
          console.log('Notifications disabled')
          return
        }

        if (pref === 'true') {
          if (Notification.permission === 'granted') {
            initMessaging(registration)
          } else if (Notification.permission === 'denied') {
            // we need to ask user for reset permission if they want to enable notification
            console.warn("Notification permission is denied but user turned on notification in settings")
          } else if (Notification.permission === 'default') {
            showPermissionPrompt(registration)
          }
          return
        }

        if (Notification.permission === 'granted') {
          updatePreference(true)
          initMessaging(registration)
        } else if (Notification.permission === 'denied') {
          updatePreference(false)
        } else {
          showPermissionPrompt(registration)
        }
      })
      .catch((error) => {
        console.error('Service worker registration failed:', error)
      })
  })
}
