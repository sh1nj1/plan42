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
export function listenForTreeReloads({ reload, release }) {
  const handleDrop = (event) => {
    if (!event?.detail?.rendered) reload()
  }
  document.addEventListener('creative-sync:refetch', reload)
  document.addEventListener('creative-sync:release', release)
  window.addEventListener('collavre:creative-drop-complete', handleDrop)
  return () => {
    document.removeEventListener('creative-sync:refetch', reload)
    document.removeEventListener('creative-sync:release', release)
    window.removeEventListener('collavre:creative-drop-complete', handleDrop)
  }
}
