// Keep persisted attachments as links; both display paths derive the same viewer.
export function pptAttachmentProps(src, filename) {
  if (!/\.pptx$/i.test(filename)) return null
  const match = String(src).match(/^(?:https?:\/\/[^/]+)?\/(?:rails\/active_storage\/blobs\/(?:redirect\/|proxy\/)?|public-assets\/blobs\/)([^/?#]+)\//)
  if (!match) return null
  return {
    className: 'ppt-attachment-preview',
    src: `/ppt_previews/${encodeURIComponent(match[1])}`,
    title: filename,
    loading: 'lazy',
    allow: 'fullscreen',
    allowFullScreen: true,
  }
}
