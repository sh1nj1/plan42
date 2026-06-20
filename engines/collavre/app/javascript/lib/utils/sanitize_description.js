import DOMPurify from 'dompurify'

// Trusted YouTube embed origins. The server's `embed_youtube_iframe` helper
// (app/helpers/application_helper.rb) only ever emits `youtube.com/embed/...`
// iframes, so we mirror that here and refuse every other iframe source.
const YOUTUBE_EMBED_SRC =
  /^https:\/\/(www\.)?(youtube\.com|youtube-nocookie\.com)\/embed\//i

// DOMPurify's default config strips <iframe> entirely, which silently removed
// the YouTube preview iframe the server had already generated — the description
// rendered blank. Re-allow iframes, but only from trusted YouTube embed origins
// so arbitrary iframe injection (clickjacking / XSS) stays blocked.
DOMPurify.addHook('uponSanitizeElement', (node, data) => {
  if (data.tagName !== 'iframe') return
  const src = node.getAttribute && node.getAttribute('src')
  if (!src || !YOUTUBE_EMBED_SRC.test(src)) {
    node.parentNode && node.parentNode.removeChild(node)
  }
})

// Mirrors the iframe attributes in EMBED_ALLOWED_ATTRS server-side.
const PURIFY_CONFIG = {
  ADD_TAGS: ['iframe'],
  ADD_ATTR: ['allow', 'allowfullscreen', 'frameborder']
}

// Sanitize creative description HTML for client-side rendering while keeping the
// server-generated YouTube preview iframe intact.
export function sanitizeDescriptionHtml(html) {
  return DOMPurify.sanitize(html ?? '', PURIFY_CONFIG)
}
