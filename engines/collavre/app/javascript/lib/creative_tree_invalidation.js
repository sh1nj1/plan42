export function invalidateCreativeTree() {
  document.dispatchEvent(new CustomEvent('creative-sync:refetch'))
  document.dispatchEvent(new CustomEvent('workspace-tree:invalidate'))
}
