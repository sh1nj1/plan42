export function commentIdFromUrl(value) {
  const url = new URL(value, window.location.origin)
  const params = url.searchParams
  const queryCommentId = params.get('comment_id') || params.get('highlight_comment_id')
  if (queryCommentId) return queryCommentId

  const pathCommentId = url.pathname.match(/\/creatives\/\d+\/comments\/(\d+)/)?.[1]
  if (pathCommentId) return pathCommentId

  return url.hash.match(/comment_(\d+)/)?.[1]
}

export function commentsRequestedFromUrl(value) {
  const url = new URL(value, window.location.origin)
  if (url.searchParams.get('open_comments') === 'true') return true
  return Boolean(commentIdFromUrl(url))
}

export function workspaceChatOptions(requestUrl, authoritative) {
  const url = requestUrl || window.location.href
  return {
    highlightId: authoritative ? commentIdFromUrl(url) : undefined,
    openRequested: authoritative && commentsRequestedFromUrl(url),
  }
}
