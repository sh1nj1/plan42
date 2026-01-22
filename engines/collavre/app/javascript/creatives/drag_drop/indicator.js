let linkHoverIndicator;
let initialized = false;

function appendLinkHoverIndicator() {
  if (!linkHoverIndicator) return;
  (document.body || document.documentElement).appendChild(linkHoverIndicator);
}

export function initIndicator() {
  if (initialized) return;
  initialized = true;

  linkHoverIndicator = document.createElement('div');
  linkHoverIndicator.className = 'creative-link-drop-indicator';
  linkHoverIndicator.textContent = '-->';
  linkHoverIndicator.style.display = 'none';

  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', appendLinkHoverIndicator, { once: true });
  } else {
    appendLinkHoverIndicator();
  }
}

export function showLinkHover(x, y) {
  if (!linkHoverIndicator) return;
  linkHoverIndicator.style.display = 'block';
  linkHoverIndicator.style.left = `${x}px`;
  linkHoverIndicator.style.top = `${y}px`;
}

export function hideLinkHover() {
  if (!linkHoverIndicator) return;
  linkHoverIndicator.style.display = 'none';
}
