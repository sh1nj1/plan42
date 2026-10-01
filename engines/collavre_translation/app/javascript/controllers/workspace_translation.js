import { sanitizeDescriptionHtml } from "collavre/lib/utils/sanitize_description"

const TREE = '.creative-workspace-tree-link'
export const PROTECTED = 'pre, code, script, style, textarea, .mention, [data-mention], [data-lexical-mention], [contenteditable], [data-ppt-slide]'

export function translationSource(row) {
  return row.matches(TREE) ? row.dataset.originalLabel : row.descriptionHtml
}

export function translationContent(row) {
  return row.matches(TREE) ? row : row.querySelector('.creative-content, .creative-title-content')
}

function label(content) {
  return content.textContent.replace(/\s+/gu, ' ').trim()
}

export function treeTranslation(result, source) {
  const content = document.createElement('div')
  content.innerHTML = sanitizeDescriptionHtml(result.original_html)
  const original = label(content)
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
  return { ...result, content: JSON.stringify([{ original, translated: label(content) }]) }
}
