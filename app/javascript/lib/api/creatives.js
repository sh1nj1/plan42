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
  return csrfFetch(url).then((response) => response.text())
}

export function save(action, method, form) {
  return csrfFetch(action, {
    method,
    headers: JSON_HEADERS,
    body: new FormData(form),
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
  save,
  destroy,
  unconvert,
}

export default creativesApi
