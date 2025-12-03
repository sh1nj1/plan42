import creativesApi from './api/creatives'
import CommonPopup from './common_popup'
import { getCaretClientRect } from '../utils/caret_position'

let initialized = false
let popupElement = null
let searchInput = null
let resultsList = null
let closeButton = null
let popupInstance = null
let onSelectCallback = null
let onCloseCallback = null

function ensureInitialized() {
  if (initialized) return popupInstance

  popupElement = document.getElementById('link-creative-modal')
  searchInput = document.getElementById('link-creative-search')
  resultsList = document.getElementById('link-creative-results')
  closeButton = document.getElementById('close-link-creative-modal')

  if (!popupElement || !searchInput || !resultsList) return null

  popupInstance = new CommonPopup(popupElement, {
    listElement: resultsList,
    renderItem: (item) => item.label || '',
    onSelect: handleSelect,
    onClose: handleClosed,
  })

  searchInput.addEventListener('input', searchLinkCreatives)
  searchInput.addEventListener('keydown', handleKeydown)
  closeButton?.addEventListener('click', hideLinkSelection)

  initialized = true
  return popupInstance
}

function handleKeydown(event) {
  if (popupInstance?.handleKey(event)) return
  if (event.key === 'Escape') {
    hideLinkSelection()
  }
}

function handleClosed() {
  if (typeof onCloseCallback === 'function') {
    onCloseCallback()
  }
  onSelectCallback = null
  onCloseCallback = null
}

function handleSelect(item) {
  if (typeof onSelectCallback === 'function') {
    onSelectCallback(item)
  }
  hideLinkSelection()
}

function searchLinkCreatives() {
  if (!searchInput || !popupInstance) return
  const query = searchInput.value.trim()
  if (!query) {
    popupInstance.setItems([])
    return
  }

  creativesApi
    .search(query, { simple: true })
    .then((results) => {
      const items = Array.isArray(results)
        ? results.map((result) => ({ id: result.id, label: result.description }))
        : []
      popupInstance.setItems(items)
      positionPopup()
    })
    .catch(() => popupInstance.setItems([]))
}

function positionPopup(anchorRect) {
  if (!popupInstance || !searchInput) return
  const caretRect = anchorRect || getCaretClientRect(searchInput) || searchInput.getBoundingClientRect()
  popupInstance.showAt(caretRect)
}

export function openLinkSelection({ anchorRect, onSelect, onClose } = {}) {
  const instance = ensureInitialized()
  if (!instance) return false

  onSelectCallback = onSelect || null
  onCloseCallback = onClose || null

  instance.setItems([])
  positionPopup(anchorRect)

  requestAnimationFrame(() => {
    searchInput?.focus()
    positionPopup(anchorRect)
  })

  return true
}

export function hideLinkSelection() {
  popupInstance?.hide()
}

export function linkSelectionOpen() {
  return popupInstance?.isOpen() || false
}
