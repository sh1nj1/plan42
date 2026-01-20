// Doorkeeper token copy functionality
// Handles copying access tokens and closing the token modal

function showCopyFeedback(btn, success) {
  if (!btn) return
  const originalText = btn.innerText
  btn.innerText = success ? 'Copied!' : 'Failed'
  setTimeout(function() {
    btn.innerText = originalText
  }, 2000)
}

function copyToken() {
  const tokenElement = document.getElementById('generated-token')
  if (!tokenElement) return

  const tokenText = tokenElement.innerText.trim()
  const btn = document.querySelector('#token-modal [data-action="copy-token"]')

  // Feature detection for clipboard API
  if (navigator.clipboard && typeof navigator.clipboard.writeText === 'function') {
    navigator.clipboard.writeText(tokenText).then(function() {
      showCopyFeedback(btn, true)
    }, function() {
      // Clipboard API failed, try fallback
      copyTokenFallback(tokenText, btn)
    })
  } else {
    // No clipboard API, use fallback
    copyTokenFallback(tokenText, btn)
  }
}

function copyTokenFallback(text, btn) {
  // Fallback for non-secure contexts or older browsers
  const textarea = document.createElement('textarea')
  textarea.value = text
  textarea.style.position = 'fixed'
  textarea.style.opacity = '0'
  document.body.appendChild(textarea)
  textarea.select()
  try {
    const success = document.execCommand('copy')
    showCopyFeedback(btn, success)
    if (!success) {
      console.error('execCommand copy returned false')
    }
  } catch (err) {
    showCopyFeedback(btn, false)
    console.error('Could not copy text: ', err)
  }
  document.body.removeChild(textarea)
}

function closeTokenModal() {
  const modal = document.getElementById('token-modal')
  if (modal) {
    modal.style.display = 'none'
  }
}

// Make functions available globally for use in views
if (typeof window !== 'undefined') {
  window.copyToken = copyToken
  window.closeTokenModal = closeTokenModal
}

function setupTokenModalListeners() {
  const copyBtn = document.querySelector('#token-modal [data-action="copy-token"]')
  if (copyBtn) {
    // Use onclick assignment to avoid duplicate listeners on Turbo cache restore
    copyBtn.onclick = copyToken
  }

  const closeBtn = document.querySelector('#token-modal [data-action="close-modal"]')
  if (closeBtn) {
    // Use onclick assignment to avoid duplicate listeners on Turbo cache restore
    closeBtn.onclick = closeTokenModal
  }
}

// Set up event listeners on turbo:load for Turbo-driven navigation
document.addEventListener('turbo:load', setupTokenModalListeners)

// Also handle initial page load for non-Turbo pages
if (document.readyState === 'loading') {
  document.addEventListener('DOMContentLoaded', setupTokenModalListeners)
} else {
  setupTokenModalListeners()
}
