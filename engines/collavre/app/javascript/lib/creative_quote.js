// Document-mode quotes: a passage selected in the creative document, sent to
// chat as a "review" (revise it) or "question" (ask about it) quote. Rows are
// flat <creative-tree-row> elements that know their parent through parent-id.

const ROW_SELECTOR = 'creative-tree-row'
const BODY_SELECTOR = '.creative-content, .creative-title-content'
// UI inside a row body that is not document text.
const NON_TEXT_SELECTOR = 'button, input, select, textarea, img, video, audio, .creative-progress-area'
const LABEL_LENGTH = 40

function rowFor(creativeId, root) {
  if (!creativeId) return null
  return root.querySelector(`${ROW_SELECTOR}[creative-id="${CSS.escape(String(creativeId))}"]`)
}

function parentIdOf(creativeId, root) {
  const row = rowFor(creativeId, root)
  const parentId = row?.getAttribute('parent-id') || row?.parentId
  return parentId ? String(parentId) : null
}

function ancestry(creativeId, root) {
  const chain = []
  const seen = new Set()
  let id = creativeId ? String(creativeId) : null
  while (id && !seen.has(id)) {
    chain.push(id)
    seen.add(id)
    id = parentIdOf(id, root)
  }
  return chain
}

// The nearest creative containing every quoted creative, so one edit scope
// covers a selection that spans rows. Rows missing from the page (the user
// navigated away) stop the walk, which falls back to the first creative.
export function commonAncestorCreativeId(ids, root = document) {
  const unique = [...new Set(ids.filter(Boolean).map(String))]
  if (unique.length === 0) return null
  if (unique.length === 1) return unique[0]

  const [first, ...rest] = unique.map(id => ancestry(id, root))
  const shared = first.find(id => rest.every(chain => chain.includes(id)))
  return shared || unique[0]
}

export function creativeQuoteTarget(quotes, root = document) {
  if (!quotes || quotes.length === 0) return null
  return {
    creativeId: commonAncestorCreativeId(quotes.map(q => q.creativeId), root),
    text: quotes[0].text,
  }
}

export function creativeLabel(row) {
  const body = row?.querySelector(BODY_SELECTOR)
  const text = (body?.textContent || '').replace(/\s+/gu, ' ').trim()
  return text.length > LABEL_LENGTH ? `${text.slice(0, LABEL_LENGTH - 1)}…` : text
}

// Desktop only: touch devices keep their native selection UI, as in chat.
export function selectionPopupSupported(win = window) {
  return Boolean(win.matchMedia?.('(hover: hover) and (pointer: fine)').matches)
}

// The quote a selection inside `root` stands for, or null when the selection
// is not plain document text: outside row bodies, inside the inline editor,
// or on non-text UI such as buttons, media and progress.
export function quoteFromSelection(selection, root) {
  if (!selection || selection.isCollapsed || selection.rangeCount === 0) return null
  const text = selection.toString().trim()
  if (!text) return null

  const range = selection.getRangeAt(0)
  const container = range.commonAncestorContainer
  const element = container.nodeType === Node.ELEMENT_NODE ? container : container.parentElement
  if (!element || !root.contains(element)) return null
  if (element.closest('#inline-edit-form') || element.closest(NON_TEXT_SELECTOR)) return null

  const rows = [...root.querySelectorAll(ROW_SELECTOR)].filter((row) => {
    const body = row.querySelector(BODY_SELECTOR)
    return body && range.intersectsNode(body)
  })
  if (rows.length === 0) return null

  const ids = rows.map(row => row.getAttribute('creative-id') || row.creativeId).filter(Boolean)
  const creativeId = commonAncestorCreativeId(ids, root)
  if (!creativeId) return null

  return { creativeId, text, label: creativeLabel(rowFor(creativeId, root) || rows[0]) }
}

export function scrollToCreativeRow(creativeId, root = document) {
  const row = rowFor(creativeId, root)
  if (!row) return false
  row.scrollIntoView({ behavior: 'smooth', block: 'center' })
  row.classList.add('creative-quote-highlight')
  setTimeout(() => row.classList.remove('creative-quote-highlight'), 2000)
  return true
}
