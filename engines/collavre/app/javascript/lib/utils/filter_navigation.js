// Shared navigation for the creative list filters (GNB chat button and the
// search popup).
//
// Two things these filters have in common:
//
//   1. Their parameters (comment, min_progress, search, show_archived,
//      search_mode) are only consumed by Creatives::IndexQuery, so a toggle
//      pressed anywhere else has to land on the creative index rather than
//      decorate the current path with a parameter nothing reads.
//   2. In workspace mode the list is rendered inside the
//      #creative-workspace-content turbo-frame, so only that frame needs to be
//      replaced. Assigning window.location.href bypasses Turbo entirely and
//      rebuilds the whole page — assets, workspace tree and docked chat
//      included.

export const WORKSPACE_FRAME_ID = 'creative-workspace-content'

// The creative index is reachable at both "/" (root route) and "/creatives",
// so `onIndex` has to come from the server; a pathname comparison would get
// the root route wrong.
export function buildFilterUrl({ indexPath, onIndex }, mutate) {
  const url = onIndex
    ? new URL(window.location.href)
    : new URL(indexPath || '/', window.location.origin)

  mutate(url.searchParams)
  return url
}

// Shared by the GNB component and the search popup's progress/comment buttons.
export function applyFilterParam(params, filter) {
  if (filter === 'comment') {
    if (params.get('comment') === 'true') {
      params.delete('comment')
    } else {
      params.set('comment', 'true')
    }
    return
  }

  params.delete('min_progress')
  params.delete('max_progress')

  if (filter === 'complete') {
    params.set('min_progress', '1')
    params.set('max_progress', '1')
  } else if (filter === 'incomplete') {
    params.set('min_progress', '0')
    params.set('max_progress', '0.99')
  }
}

// Returns true when only the workspace frame was replaced, meaning the GNB
// survived the navigation and its server-rendered state is now stale.
//
// Turbo is imported unconditionally by application.js, so it is assumed
// present here the same way creative_tree_row.js assumes it.
export function visitFilterUrl(url) {
  const frame = document.getElementById(WORKSPACE_FRAME_ID)

  window.Turbo.visit(
    `${url.pathname}${url.search}`,
    frame ? { action: 'advance', frame: WORKSPACE_FRAME_ID } : { action: 'advance' }
  )
  return Boolean(frame)
}

function progressState(params) {
  const min = params.get('min_progress')
  const max = params.get('max_progress')
  if (min === '1' && max === '1') return 'complete'
  if (min === '0' && max === '0.99') return 'incomplete'
  return 'all'
}

// Re-derives the `active` classes the server would have rendered for the URL
// we are navigating to. Mirrors _search_form.html.erb; only needed on the
// frame path, where the GNB is not re-rendered.
export function syncFilterButtons(url) {
  const params = url.searchParams
  const hasProgress = Boolean(params.get('min_progress') || params.get('max_progress'))
  const hasArchived = params.get('show_archived') === 'true'
  const active = {
    [`progress:${progressState(params)}`]: true,
    comment: params.get('comment') === 'true',
    archived: hasArchived,
    'any-filter': hasProgress || hasArchived || Boolean(params.get('search'))
  }

  document.querySelectorAll('[data-filter-state]').forEach((element) => {
    const isActive = active[element.dataset.filterState] === true
    element.classList.toggle('active', isActive)

    // Buttons whose label depends on the filter state (archive show/hide)
    // carry both translations so they can be swapped without a round trip.
    const label = isActive ? element.dataset.labelOn : element.dataset.labelOff
    if (label) element.textContent = label
  })
}
