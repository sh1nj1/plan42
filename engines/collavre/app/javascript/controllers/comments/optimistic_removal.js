// Hide comments before the server confirms their deletion. The server only
// marks a selection and destroys it in the background, so the list should not
// wait on it; restore() brings the rows back if the request is refused.
export function hideCommentsOptimistically(commentIds) {
  const elements = commentIds
    .map((id) => document.getElementById(`comment_${id}`))
    .filter(Boolean)
  elements.forEach((el) => { el.style.display = 'none' })

  return {
    ids: commentIds,
    commit() { elements.forEach((el) => el.remove()) },
    restore() { elements.forEach((el) => { el.style.display = '' }) },
  }
}
