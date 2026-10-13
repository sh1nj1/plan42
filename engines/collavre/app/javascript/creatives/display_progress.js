// Keep filtered presentation progress separate from raw inline-editor data.
export function applyDisplayProgress(row, node) {
  if (node.display_progress != null) {
    row.dataset.displayProgress = String(node.display_progress)
  } else if (Object.prototype.hasOwnProperty.call(node, 'display_progress')) {
    row.removeAttribute('data-display-progress')
  }
  return node.inline_editor_payload || {}
}
