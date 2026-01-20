// OAuth callback handler
// Notifies parent window of successful OAuth authentication and closes popup

document.addEventListener('DOMContentLoaded', function() {
  // Check for OAuth callback data attribute on body
  const body = document.body
  const callbackType = body.dataset.oauthCallback

  if (callbackType) {
    try {
      if (window.opener) {
        window.opener.postMessage({ type: callbackType }, window.location.origin)
      }
    } catch (e) {
      console.error('Failed to notify opener', e)
    }
    window.close()
  }
})
