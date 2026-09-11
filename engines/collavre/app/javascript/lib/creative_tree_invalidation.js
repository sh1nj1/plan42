export function invalidateCreativeTree(detail = {}) {
  document.dispatchEvent(new CustomEvent('creative-sync:refetch'))
  document.dispatchEvent(new CustomEvent('workspace-tree:invalidate', { detail }))
}
