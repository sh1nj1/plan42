// True when an HTML fragment has no user-visible content. Treats inline
// images and attachments (action-text-attachment / figure.attachment /
// data-trix-attachment) as content so image-only or attachment-only bodies
// don't get discarded silently when switching editor modes.
export function isHtmlEmpty(html, doc = typeof document !== 'undefined' ? document : null) {
  if (!html) return true;
  if (!doc) return html.replace(/<[^>]*>/g, '').trim().length === 0;
  const temp = doc.createElement('div');
  temp.innerHTML = html;
  if (temp.querySelector('img, action-text-attachment, figure.attachment, [data-trix-attachment]')) return false;
  return (temp.textContent || '').trim().length === 0;
}
