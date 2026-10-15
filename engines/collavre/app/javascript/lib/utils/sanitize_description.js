import { decorateAttachmentLinks } from "../lexical/attachment_presentation"
import DOMPurify from 'dompurify'

// Trusted YouTube embed origins. The server's `embed_youtube_iframe` helper
// (app/helpers/application_helper.rb) only ever emits `youtube.com/embed/...`
// iframes. Also allow the local, authorized PPT preview endpoint.
const YOUTUBE_EMBED_SRC =
  /^https:\/\/(www\.)?(youtube\.com|youtube-nocookie\.com)\/embed\//i

// DOMPurify's default config strips <iframe> entirely, which silently removed
// the YouTube preview iframe the server had already generated — the description
// rendered blank. Re-allow iframes, but only from trusted YouTube embed origins
// so arbitrary iframe injection (clickjacking / XSS) stays blocked.
DOMPurify.addHook('uponSanitizeElement', (node, data) => {
  if (data.tagName !== 'iframe') return
  const src = node.getAttribute && node.getAttribute('src')
  if (!src || !(YOUTUBE_EMBED_SRC.test(src) || /^\/(?:[A-Za-z0-9%_.~-]+\/)*ppt_previews\/[A-Za-z0-9%_=.-]+$/.test(src))) {
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
  const fragment = DOMPurify.sanitize(html ?? '', {...PURIFY_CONFIG, RETURN_DOM_FRAGMENT: true})
  decorateAttachmentLinks(fragment)
  const container = document.createElement('div')
  container.append(fragment)
  return container.innerHTML
}
