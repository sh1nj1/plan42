import livestoreClient from './livestore.client';

const creativesApi = {
  get(id) {
    return livestoreClient.getCreative(id).then((data) => {
      if (data) return data;
      return fetch(`/creatives/${id}.json`).then((r) => r.json());
    });
  },

  parentSuggestions(id) {
    return fetch(`/creatives/${id}/parent_suggestions.json`).then((r) => r.json());
  },

  loadChildren(url) {
    return fetch(url).then((r) => r.text());
  },

  save(action, method, form) {
    return livestoreClient.saveForm(action, method, form);
  },

  destroy(id, withChildren) {
    return livestoreClient.destroyCreative(id, withChildren);
  },
};

export default creativesApi;

if (!window.creativesApi) {
  window.creativesApi = creativesApi;
}
