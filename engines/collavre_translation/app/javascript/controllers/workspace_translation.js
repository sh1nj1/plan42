import { sanitizeDescriptionHtml } from "collavre/lib/utils/sanitize_description"

export const LABEL = '.creative-workspace-tree-link, [data-translation-label]'
export const ROWS = `creative-tree-row[creative-id], ${LABEL}`
export const PROTECTED = 'pre, code, script, style, textarea, .mention, [data-mention], [data-lexical-mention], [contenteditable], [data-ppt-slide]'

export function translationSource(row) {
  return row.matches(LABEL) ? row.dataset.originalLabel : row.descriptionHtml
}

export function translationContent(row) {
  return row.matches(LABEL) ? row : row.querySelector('.creative-content, .creative-title-content')
}

// Tree labels come from the stored description, so ask for it unembedded.
export function translationUrl(base, row) {
  const url = base.replace('__ID__', row.getAttribute('creative-id') || row.dataset.creativeId)
  return row.matches(LABEL) ? `${url}?embed=0` : url
}

function label(content) {
  return content.textContent.replace(/\s+/gu, ' ').trim()
}

export function treeTranslation(result, source, row) {
  const content = document.createElement('div')
  content.innerHTML = sanitizeDescriptionHtml(result.original_html)
  const original = truncateLabel(label(content), row)
  if (original !== source) return null
  if (result.status !== 'completed') return result
  const replacements = new Map(JSON.parse(result.content).map(pair => [pair.original, pair.translated]))
  const walker = document.createTreeWalker(content, NodeFilter.SHOW_TEXT)
  while (walker.nextNode()) {
    const node = walker.currentNode
    if (!node.parentElement.closest(PROTECTED) && replacements.has(node.textContent)) {
      node.textContent = replacements.get(node.textContent)
    }
  }
  return { ...result, content: JSON.stringify([{ original, translated: truncateLabel(label(content), row) }]) }
}

function truncateLabel(text, row) {
  const length = Number(row?.dataset.translationLength)
  const chars = Array.from(text)
  return length > 0 && chars.length > length ? chars.slice(0, length - 3).join('') + '...' : text
}
