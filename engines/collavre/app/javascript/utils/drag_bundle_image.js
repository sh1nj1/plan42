/**
 * Creates a stacked-card "bundle" drag image for multi-select drag operations.
 *
 * @param {number} count - Total number of selected items
 * @param {string} previewText - Text to display on the front card
 * @returns {HTMLElement} The drag image element (append to body, then remove after setDragImage)
 */
export function createBundleDragImage(count, previewText) {
  const container = document.createElement('div')
  container.className = 'drag-bundle-image'

  // Stacked cards behind the primary card
  if (count > 2) {
    const backCard = document.createElement('div')
    backCard.className = 'drag-bundle-card drag-bundle-card--back'
    container.appendChild(backCard)
  }
  if (count > 1) {
    const midCard = document.createElement('div')
    midCard.className = 'drag-bundle-card drag-bundle-card--mid'
    container.appendChild(midCard)
  }

  // Front card with text preview
  const frontCard = document.createElement('div')
  frontCard.className = 'drag-bundle-card drag-bundle-card--front'
  const truncated = previewText.length > 40 ? previewText.slice(0, 40) + '…' : previewText
  frontCard.textContent = truncated || '—'
  container.appendChild(frontCard)

  // Count badge
  if (count > 1) {
    const badge = document.createElement('span')
    badge.className = 'drag-bundle-badge'
    badge.textContent = count
    container.appendChild(badge)
  }

  return container
}

/**
 * Attaches a bundle drag image to a drag event and schedules cleanup.
 *
 * @param {DragEvent} event
 * @param {number} count - Total number of selected items
 * @param {string} previewText - Text preview for the front card
 */
export function attachBundleDragImage(event, count, previewText) {
  const dragImage = createBundleDragImage(count, previewText)
  document.body.appendChild(dragImage)
  event.dataTransfer.setDragImage(dragImage, 24, 24)
  requestAnimationFrame(() => dragImage.remove())
}
