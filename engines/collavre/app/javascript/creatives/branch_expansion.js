import { setExpanded, setHasChildren } from './drag_drop/dom'
import { loadChildren } from '../lib/api/creatives'
import { renderCreativeTree, dispatchCreativeTreeUpdated } from './tree_renderer'

// A collapsed branch is rendered empty with `data-loaded="false"`, so revealing
// its container on its own shows nothing. Fill it the way a click-driven
// expansion does (expansion_controller#ensureLoaded) before expanding, or the
// branch looks open but blank — and, mid-drag, offers no rows to drop onto.
export function expandBranchWithChildren(row, container) {
  if (!container) return Promise.resolve(false)

  const loadUrl = container.dataset.loadUrl
  if (container.dataset.loaded === 'true' || !loadUrl) {
    setExpanded(row, true, container)
    return Promise.resolve(true)
  }

  return loadChildren(loadUrl)
    .then((data) => {
      const nodes = Array.isArray(data?.creatives) ? data.creatives : []
      renderCreativeTree(container, nodes)
      container.dataset.loaded = 'true'
      const hasChildren = !!container.querySelector('creative-tree-row')
      setHasChildren(row, hasChildren)
      if (!hasChildren) {
        setExpanded(row, false, container)
        dispatchCreativeTreeUpdated(container)
        return false
      }
      dispatchCreativeTreeUpdated(container)
      setExpanded(row, true, container)
      return true
    })
    .catch((error) => {
      console.error('Failed to load children for branch expansion', error)
      return false
    })
}
