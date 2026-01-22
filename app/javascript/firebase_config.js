// Firebase configuration loader
// Reads config from meta tag to avoid inline script

document.addEventListener('DOMContentLoaded', () => {
  const meta = document.querySelector('meta[name="firebase-config"]')
  if (meta && meta.content) {
    try {
      window.firebaseConfig = JSON.parse(meta.content)
    } catch (e) {
      console.error('Failed to parse Firebase config:', e)
    }
  }
})
