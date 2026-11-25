// What makes the creative list refetch itself, and what only lets a refetch it
// already owes go ahead. Returns the function that stops listening.
//
//   creative-sync:refetch            something changed that the list cannot
//                                    render from what it has
//   creative-sync:release            a save settled; the row already shows it,
//                                    so only a reload held back by it is due
//   collavre:creative-drop-complete  a drop landed; the list refetches unless it
//                                    rendered the drop in place (`rendered`). A
//                                    drop from the workspace tree or another
//                                    window, a multi-row or link drop and a drop
//                                    into an unloaded branch all leave it behind
//
// A filtered list is the exception to both shortcuts: which rows it holds and
// the progress each shows come from the filter, so only a refetch can say what
// a save or a drop did to it.
const FILTER_PARAMS = [
  'tags', 'min_progress', 'max_progress', 'search', 'has_comments', 'has_cron', 'reaction_emoji',
  'due_before', 'due_after', 'has_due_date', 'assignee_id', 'unassigned', 'comment',
]

// Mirrors Creatives::FilterState#active? for the URL the list loads from.
export function listIsFiltered() {
  const url = document.querySelector('[data-creatives--tree-url-value]')?.getAttribute('data-creatives--tree-url-value')
  const params = new URL(url || '', window.location.origin).searchParams
  return FILTER_PARAMS.some((name) => [name, `${name}[]`].some((key) => params.getAll(key).some(Boolean)))
}

export function listenForTreeReloads({ reload, release }) {
  const handleSettled = () => (listIsFiltered() ? reload() : release())
  const handleDrop = (event) => {
    if (listIsFiltered() || !event?.detail?.rendered) reload()
  }
  document.addEventListener('creative-sync:refetch', reload)
  document.addEventListener('creative-sync:release', handleSettled)
  window.addEventListener('collavre:creative-drop-complete', handleDrop)
  return () => {
    document.removeEventListener('creative-sync:refetch', reload)
    document.removeEventListener('creative-sync:release', handleSettled)
    window.removeEventListener('collavre:creative-drop-complete', handleDrop)
  }
}
