if (!window.creativesApi) {
  window.creativesApi = {
    get(id) {
      return fetch(`/creatives/${id}.json`).then(r => r.json());
    },
    parentSuggestions(id) {
      return fetch(`/creatives/${id}/parent_suggestions.json`).then(r => r.json());
    },
    tree(parentId) {
      const param = parentId ? `?id=${parentId}` : '';
      return fetch(`/creatives/tree.json${param}`).then(r => r.json());
    },
    loadChildren(url) {
      return fetch(url).then(r => r.text());
    },
    save(action, method, form) {
      return fetch(action, {
        method: method,
        headers: {
          'Accept': 'application/json',
          'X-CSRF-Token': document.querySelector('meta[name="csrf-token"]').content
        },
        body: new FormData(form),
        credentials: 'same-origin'
      });
    },
    destroy(id, withChildren) {
      return fetch(`/creatives/${id}${withChildren ? '?delete_with_children=true' : ''}`, {
        method: 'DELETE',
        headers: { 'X-CSRF-Token': document.querySelector('meta[name="csrf-token"]').content },
        credentials: 'same-origin'
      });
    }
  };
}
