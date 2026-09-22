// True when an HTML fragment has no user-visible content. Treats inline
// images and attachments (action-text-attachment / figure.attachment /
// data-trix-attachment) as content so image-only or attachment-only bodies
// don't get discarded silently when switching editor modes.
export function isHtmlEmpty(html, doc = typeof document !== 'undefined' ? document : null) {
  if (!html) return true;
  const Parser = doc?.defaultView?.DOMParser ?? globalThis.DOMParser;
  if (!Parser) return html.replace(/<[^>]*>/g, '').trim().length === 0;
  // Parse in an inert document: even a detached element in the active document
  // can execute resource event handlers when untrusted HTML is assigned to it.
  const temp = new Parser().parseFromString(html, 'text/html').body;
  if (temp.querySelector('img, action-text-attachment, figure.attachment, [data-trix-attachment]')) return false;
  return (temp.textContent || '').trim().length === 0;
}
