export function horizontalHit({ el, event }) {
  const rect = el.getBoundingClientRect()
  return event.clientX < rect.left + rect.width / 2 ? 'left' : 'right'
}

export function previewDrop({ el, hit }) {
  const className = `dnd-over-${hit}`
  el.classList.add(className)
  return () => el.classList.remove(className)
}
