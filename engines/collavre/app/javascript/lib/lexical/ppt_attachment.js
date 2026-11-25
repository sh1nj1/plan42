import { mediaLoadingProps } from "../media_loading"
// Keep persisted attachments as links; both display paths derive the same viewer.
export function pptAttachmentProps(src, filename) {
  if (!/\.(pptx|md|html|pdf)$/i.test(filename)) return null
  const match = String(src).match(/^(?:https?:\/\/[^/]+)?\/(?:[^/?#]+\/)*(?:rails\/active_storage\/blobs\/(?:redirect\/|proxy\/)?|public-assets\/blobs\/)([^/?#]+)\//)
  const template = document.querySelector('meta[name="ppt-preview-url-template"]')?.content
  if (!match || !template) return null
  return {
    className: 'document-preview-frame',
    src: template.replace('PPT_BLOB_ID', encodeURIComponent(match[1])),
    title: filename,
    loading: 'lazy',
    'data-action': 'load->document-preview#loaded',
    allow: 'fullscreen',
    allowFullScreen: true,
  }
}

export function previewContainerProps() {
  return {className: 'ppt-attachment-preview', 'data-controller': 'document-preview', 'aria-busy': 'true'}
}

export function previewLoadingProps() {
  return {...mediaLoadingProps(),
    'data-document-preview-target': 'loading'}
}
