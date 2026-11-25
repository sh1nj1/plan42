export function bindViewerNavigation(viewer, actions) {
  viewer.querySelector('[data-ppt-previous]').addEventListener('click', actions.previous)
  viewer.querySelector('[data-ppt-next]').addEventListener('click', actions.next)
  viewer.ownerDocument.addEventListener('keydown', event => {
    if (!viewer.isConnected || !['ArrowLeft', 'ArrowRight'].includes(event.key)) return
    if (event.target.closest('input, textarea, select, [contenteditable]')) return
    event.preventDefault()
    actions[event.key === 'ArrowRight' ? 'next' : 'previous']()
  })
}

export function updateViewerNavigation(viewer, index, count) {
  viewer.querySelector('[data-ppt-counter]').textContent = `${index + 1} / ${count}`
  viewer.querySelector('[data-ppt-previous]').disabled = index === 0
  viewer.querySelector('[data-ppt-next]').disabled = index === count - 1
}
