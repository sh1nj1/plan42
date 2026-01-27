import csrfFetch from './csrf_fetch'

const JSON_HEADERS = { Accept: 'application/json' }

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

export function save(action, method, form) {
  return csrfFetch(action, {
    method,
    headers: JSON_HEADERS,
    body: new FormData(form),
  })
}

export function linkExisting(parentId, originId) {
  const body = new FormData()
  if (parentId != null) body.append('creative[parent_id]', parentId)
  if (originId != null) body.append('creative[origin_id]', originId)

  return csrfFetch('/creatives', {
    method: 'POST',
    headers: JSON_HEADERS,
    body,
  })
}

export function destroy(id, withChildren = false) {
  const query = withChildren ? '?delete_with_children=true' : ''
  return csrfFetch(`/creatives/${id}${query}`, {
    method: 'DELETE',
  })
}

export function unconvert(id) {
  return csrfFetch(`/creatives/${id}/unconvert`, {
    method: 'POST',
    headers: JSON_HEADERS,
  })
}

const creativesApi = {
  get,
  parentSuggestions,
  loadChildren,
  search,
  save,
  linkExisting,
  destroy,
  unconvert,
}

export default creativesApi
