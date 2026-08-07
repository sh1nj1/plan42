import csrfFetch from './csrf_fetch'

const JSON_HEADERS = { Accept: 'application/json' }

function invalidateWorkspaceTreeOnSuccess(response) {
  if (response.ok && typeof document !== 'undefined') {
    document.dispatchEvent(new CustomEvent('workspace-tree:invalidate'))
  }
  return response
}

export function get(id) {
  return csrfFetch(`/creatives/${id}.json`, {
    headers: JSON_HEADERS,
  }).then((response) => response.json())
}

export function parentSuggestions(id) {
  return csrfFetch(`/creatives/${id}/parent_suggestions.json`, {
    headers: JSON_HEADERS,
  }).then((response) => response.json())
}

export function loadChildren(url) {
  return csrfFetch(url, { headers: JSON_HEADERS }).then((response) => response.json())
}

// Browse the creative tree for the picker popup. Returns the lightweight
// simple payload ([{ id, description, progress, has_children }]) for the
// children of `parentId`, or the roots when `parentId` is null/undefined.
export function browse(parentId) {
  const params = new URLSearchParams({ simple: 'true' })
  if (parentId != null) params.set('id', parentId)

  return csrfFetch(`/creatives.json?${params.toString()}`, {
    headers: JSON_HEADERS,
  }).then((response) => response.json())
}

export function search(query, { simple = false } = {}) {
  const params = new URLSearchParams()
  if (query != null) params.set('search', query)
  if (simple) params.set('simple', 'true')

  const queryString = params.toString()
  const url = queryString ? `/creatives.json?${queryString}` : '/creatives.json'

  return csrfFetch(url, {
    headers: JSON_HEADERS,
  }).then((response) => response.json())
}

export function createFromTitle(title) {
  const body = new FormData()
  body.append('creative[description]', title)
  body.append('creative[content_type_input]', 'markdown')
  body.append('creative[markdown_source]', title)
  body.append('creative[markdown_editor]', 'rich')

  return csrfFetch('/creatives', {
    method: 'POST',
    headers: JSON_HEADERS,
    body,
  }).then((response) => {
    if (!response.ok) throw new Error(`Failed to create creative: ${response.status}`)
    invalidateWorkspaceTreeOnSuccess(response)
    return response.json()
  })
}

export function save(action, method, form) {
  return csrfFetch(action, {
    method,
    headers: JSON_HEADERS,
    body: new FormData(form),
  }).then(invalidateWorkspaceTreeOnSuccess)
}

export function linkExisting(parentId, originId) {
  const body = new FormData()
  if (parentId != null) body.append('creative[parent_id]', parentId)
  if (originId != null) body.append('creative[origin_id]', originId)

  return csrfFetch('/creatives', {
    method: 'POST',
    headers: JSON_HEADERS,
    body,
  }).then(invalidateWorkspaceTreeOnSuccess)
}

export function destroy(id, withChildren = false) {
  const query = withChildren ? '?delete_with_children=true' : ''
  return csrfFetch(`/creatives/${id}${query}`, {
    method: 'DELETE',
  }).then(invalidateWorkspaceTreeOnSuccess)
}

export function archive(id) {
  return csrfFetch(`/creatives/${id}/archive`, {
    method: 'PATCH',
  }).then(invalidateWorkspaceTreeOnSuccess)
}

export function unarchive(id) {
  return csrfFetch(`/creatives/${id}/unarchive`, {
    method: 'PATCH',
  }).then(invalidateWorkspaceTreeOnSuccess)
}

export function unconvert(id) {
  return csrfFetch(`/creatives/${id}/unconvert`, {
    method: 'POST',
    headers: JSON_HEADERS,
  }).then(invalidateWorkspaceTreeOnSuccess)
}

export function updateMetadata(id, data) {
  const body = new FormData()
  body.append('data', JSON.stringify(data))

  return csrfFetch(`/creatives/${id}/update_metadata`, {
    method: 'PATCH',
    headers: JSON_HEADERS,
    body,
  })
}

const creativesApi = {
  get,
  parentSuggestions,
  loadChildren,
  browse,
  search,
  createFromTitle,
  save,
  linkExisting,
  destroy,
  archive,
  unarchive,
  unconvert,
  updateMetadata,
}

export default creativesApi
