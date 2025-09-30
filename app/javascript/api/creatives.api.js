const creativesApi = {
  get(id) {
    return fetch(`/creatives/${id}.json`).then((r) => r.json());
  },

  parentSuggestions(id) {
    return fetch(`/creatives/${id}/parent_suggestions.json`).then((r) => r.json());
  },

  loadChildren(url) {
    return fetch(url).then((r) => r.text());
  },

  save(action, method, form) {
    return fetch(action, {
      method,
      headers: {
        Accept: 'application/json',
        'X-CSRF-Token': document.querySelector('meta[name="csrf-token"]')?.content,
      },
      body: new FormData(form),
      credentials: 'same-origin',
    });
  },

  destroy(id, withChildren) {
    const query = withChildren ? '?delete_with_children=true' : '';
    return fetch(`/creatives/${id}${query}`, {
      method: 'DELETE',
      headers: {
        'X-CSRF-Token': document.querySelector('meta[name="csrf-token"]')?.content,
      },
      credentials: 'same-origin',
    });
  },

  unconvert(id) {
    return fetch(`/creatives/${id}/unconvert`, {
      method: 'POST',
      headers: {
        Accept: 'application/json',
        'X-CSRF-Token': document.querySelector('meta[name="csrf-token"]')?.content,
      },
      credentials: 'same-origin',
    });
  },
};

export default creativesApi;

if (!window.creativesApi) {
  window.creativesApi = creativesApi;
}
