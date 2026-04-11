/**
 * Integration Wizard — shared helpers for integration modal wizards.
 *
 * Provides common utilities used across Slack, Notion, and future
 * integration wizard UIs: CSRF handling, error display, step management,
 * OAuth popups, fetch wrappers, and modal close behavior.
 *
 * Usage:
 *   import { csrfToken, showError, ... } from 'collavre/modules/integration_wizard'
 */

/**
 * Read the Rails CSRF token from the meta tag.
 * @returns {string|undefined}
 */
export function csrfToken() {
  return document.querySelector('meta[name="csrf-token"]')?.content;
}

/**
 * Display an error message inside the given element.
 * @param {HTMLElement} el - The error container element
 * @param {string} message - Error text to display
 */
export function showError(el, message) {
  if (!message) return;
  el.textContent = message;
  el.style.display = 'block';
}

/**
 * Hide and clear the error element.
 * @param {HTMLElement} el - The error container element
 */
export function clearError(el) {
  el.style.display = 'none';
  el.textContent = '';
}

/**
 * Show/hide step panes by step name.
 *
 * @param {string} currentStep - The active step name
 * @param {string[]} stepNames - All step names in order
 * @param {string} prefix - DOM id prefix, e.g. 'slack-step' produces ids like 'slack-step-connect'
 */
export function updateStepVisibility(currentStep, stepNames, prefix) {
  stepNames.forEach(function (step) {
    const el = document.getElementById(`${prefix}-${step}`);
    if (!el) return;
    el.style.display = (step === currentStep) ? 'block' : 'none';
  });
}

/**
 * Open a centered OAuth popup window and poll for its closure.
 *
 * @param {string} windowName - Name for window.open (e.g. 'slack-auth-window')
 * @param {Object} options
 * @param {number} [options.width=600] - Popup width
 * @param {number} [options.height=700] - Popup height
 * @param {string} [options.url=''] - URL to open (pass '' if submitting a form to the window)
 * @param {Function} [options.onClose] - Callback invoked when the popup is closed
 * @returns {Window|null} The opened window reference
 */
export function openOAuthPopup(windowName, options = {}) {
  const width = options.width || 600;
  const height = options.height || 700;
  const left = (screen.width - width) / 2;
  const top = (screen.height - height) / 2;
  const url = options.url || '';

  const authWindow = window.open(
    url,
    windowName,
    `width=${width},height=${height},left=${left},top=${top},scrollbars=yes,resizable=yes`
  );

  if (authWindow && options.onClose) {
    const checkClosed = setInterval(() => {
      if (authWindow.closed) {
        clearInterval(checkClosed);
        setTimeout(() => options.onClose(), 1000);
      }
    }, 1000);
  }

  return authWindow;
}

/**
 * Perform a fetch request with CSRF token and JSON headers.
 *
 * @param {string} url - Request URL
 * @param {Object} [options={}]
 * @param {string} [options.method='GET'] - HTTP method
 * @param {Object} [options.body] - Body payload (will be JSON-stringified)
 * @param {Object} [options.headers] - Additional headers (merged with defaults)
 * @returns {Promise<Response>}
 */
export function fetchWithCsrf(url, options = {}) {
  const method = options.method || 'GET';
  const headers = {
    'X-CSRF-Token': csrfToken(),
    'Accept': 'application/json',
    ...options.headers,
  };

  // Include Content-Type for requests with a body
  if (options.body) {
    headers['Content-Type'] = 'application/json';
  }

  const fetchOptions = { method, headers };
  if (options.body) {
    fetchOptions.body = JSON.stringify(options.body);
  }

  return fetch(url, fetchOptions);
}

/**
 * Hide a list of DOM elements (set display to 'none') and optionally clear their content.
 *
 * @param {Array<{el: HTMLElement|null, clear?: boolean}>} items
 *   Each item has an `el` (may be null) and an optional `clear` flag.
 *   When `clear` is true, textContent or innerHTML is also reset.
 */
export function resetElements(items) {
  items.forEach(function ({ el, clear }) {
    if (!el) return;
    el.style.display = 'none';
    if (clear) {
      if ('innerHTML' in el && el.tagName !== 'INPUT') {
        el.textContent = '';
      }
    }
  });
}

/**
 * Set up common modal close behavior: close button, backdrop click, and Escape key.
 *
 * @param {HTMLElement} modal - The modal overlay element
 * @param {HTMLElement} closeBtn - The close button element
 * @param {Function} onClose - Callback to execute on close (e.g. resetWizard)
 */
export function setupModalClose(modal, closeBtn, onClose) {
  if (closeBtn) {
    closeBtn.addEventListener('click', function () {
      modal.style.display = 'none';
      onClose();
    });
  }

  modal.addEventListener('click', function (e) {
    if (e.target === modal) {
      modal.style.display = 'none';
      onClose();
    }
  });
}
