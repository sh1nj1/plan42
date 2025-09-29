const LIVESTORE_META = typeof document !== 'undefined'
  ? document.querySelector('meta[name="livestore-base-url"]')
  : null;
const LIVESTORE_BASE_URL = LIVESTORE_META?.content?.replace(/\/$/, '') || null;

const storage = (() => {
  if (typeof window === 'undefined') return null;
  try {
    const testKey = '__livestore_probe__';
    window.localStorage.setItem(testKey, '1');
    window.localStorage.removeItem(testKey);
    return window.localStorage;
  } catch (error) {
    return null;
  }
})();

function schedule(task) {
  if (typeof window === 'undefined') {
    task();
    return;
  }
  const runner = () => {
    try {
      const result = task();
      if (result?.catch) {
        result.catch((error) => console.error('LiveStore async task failed', error));
      }
    } catch (error) {
      console.error('LiveStore async task failed', error);
    }
  };
  if ('requestIdleCallback' in window) {
    window.requestIdleCallback(runner);
  } else {
    window.setTimeout(runner, 0);
  }
}

function extractJson(response) {
  const contentType = response.headers.get('content-type') || '';
  if (!contentType.includes('application/json')) return Promise.resolve(null);
  return response.text().then((text) => {
    if (!text) return null;
    try {
      return JSON.parse(text);
    } catch (error) {
      console.warn('LiveStore: failed to parse JSON response', error);
      return null;
    }
  });
}

function csrfToken() {
  if (typeof document === 'undefined') return null;
  return document.querySelector('meta[name="csrf-token"]')?.content || null;
}

class LivestoreClient {
  constructor(baseUrl, backingStorage) {
    this.baseUrl = baseUrl;
    this.storage = backingStorage;
  }

  isEnabled() {
    return Boolean(this.baseUrl);
  }

  creativeKey(id) {
    return `livestore:creatives:${id}`;
  }

  cacheCreative(data) {
    if (!data || typeof data !== 'object' || !data.id || !this.storage) return data;
    try {
      this.storage.setItem(this.creativeKey(data.id), JSON.stringify(data));
    } catch (error) {
      console.warn('LiveStore: failed to cache creative', error);
    }
    return data;
  }

  getCachedCreative(id) {
    if (!id || !this.storage) return null;
    try {
      const raw = this.storage.getItem(this.creativeKey(id));
      if (!raw) return null;
      return JSON.parse(raw);
    } catch (error) {
      console.warn('LiveStore: failed to read cached creative', error);
      try { this.storage.removeItem(this.creativeKey(id)); } catch (_) {}
      return null;
    }
  }

  removeCachedCreative(id) {
    if (!id || !this.storage) return;
    try {
      this.storage.removeItem(this.creativeKey(id));
    } catch (error) {
      console.warn('LiveStore: failed to remove cached creative', error);
    }
  }

  buildLivestoreUrl(action) {
    if (!this.baseUrl) return null;
    try {
      const url = new URL(action, window.location.origin);
      return `${this.baseUrl}${url.pathname}${url.search}`;
    } catch (error) {
      console.warn('LiveStore: invalid action url', action, error);
      return null;
    }
  }

  extractIdFromAction(action) {
    try {
      const url = new URL(action, window.location.origin);
      const match = url.pathname.match(/\/creatives\/(\d+)/);
      if (match) return Number.parseInt(match[1], 10);
    } catch (error) {
      // ignore
    }
    return null;
  }

  async performLivestoreRequest(action, options = {}) {
    const url = this.buildLivestoreUrl(action);
    if (!url) return null;
    const requestInit = {
      method: options.method || 'GET',
      credentials: 'include',
      headers: new Headers(options.headers || { Accept: 'application/json' }),
    };
    const method = requestInit.method.toUpperCase();
    if (options.body && !['GET', 'HEAD'].includes(method)) {
      requestInit.body = options.body;
    }
    if (!requestInit.headers.has('Accept')) {
      requestInit.headers.set('Accept', 'application/json');
    }
    return fetch(url, requestInit);
  }

  async performServerRequest(action, method, body = null) {
    const headers = new Headers({ Accept: 'application/json' });
    const token = csrfToken();
    if (token) headers.set('X-CSRF-Token', token);
    const requestInit = {
      method,
      headers,
      credentials: 'same-origin',
    };
    if (body && !['GET', 'HEAD'].includes(method)) {
      requestInit.body = body;
    }
    return fetch(action, requestInit);
  }

  async handleResponseCaching(response, method, action) {
    if (!response) return null;
    const upperMethod = method.toUpperCase();
    const data = await extractJson(response);
    if (upperMethod === 'DELETE') {
      const id = data?.id || this.extractIdFromAction(action);
      if (id) this.removeCachedCreative(id);
      return data;
    }
    if (data && data.id) {
      this.cacheCreative(data);
      return data;
    }
    const id = this.extractIdFromAction(action);
    if (response.ok && id) {
      await this.refreshFromServer(id);
    }
    return data;
  }

  async fetchCreativeFromLivestore(id) {
    if (!this.isEnabled()) return null;
    try {
      const response = await this.performLivestoreRequest(`/creatives/${id}.json`, { method: 'GET' });
      if (!response) return null;
      if (response.status === 404) {
        this.removeCachedCreative(id);
        return null;
      }
      if (!response.ok) return null;
      const data = await extractJson(response.clone());
      if (data && data.id) {
        return this.cacheCreative(data);
      }
    } catch (error) {
      console.warn('LiveStore: failed to fetch creative from LiveStore', error);
    }
    return null;
  }

  async fetchCreativeFromServer(id) {
    try {
      const response = await fetch(`/creatives/${id}.json`, { credentials: 'same-origin' });
      if (response.status === 404) {
        this.removeCachedCreative(id);
        return null;
      }
      if (!response.ok) return null;
      const data = await response.json();
      return this.cacheCreative(data);
    } catch (error) {
      console.warn('LiveStore: failed to fetch creative from server', error);
      return null;
    }
  }

  async getCreative(id) {
    const liveData = await this.fetchCreativeFromLivestore(id);
    if (liveData) return liveData;
    const cached = this.getCachedCreative(id);
    if (cached) return cached;
    return this.fetchCreativeFromServer(id);
  }

  async saveForm(action, method, form) {
    const upperMethod = method.toUpperCase();
    let response = null;
    if (this.isEnabled()) {
      try {
        const formData = new FormData(form);
        response = await this.performLivestoreRequest(action, { method: upperMethod, body: formData });
      } catch (error) {
        console.warn('LiveStore: failed to save creative to LiveStore', error);
        response = null;
      }
      if (response) {
        await this.handleResponseCaching(response.clone(), upperMethod, action);
        this.enqueueServerSync(action, upperMethod, form);
        return response;
      }
    }
    const fallbackFormData = new FormData(form);
    const serverResponse = await this.performServerRequest(action, upperMethod, fallbackFormData);
    await this.handleResponseCaching(serverResponse.clone(), upperMethod, action);
    return serverResponse;
  }

  async destroyCreative(id, withChildren = false) {
    const query = withChildren ? '?delete_with_children=true' : '';
    const action = `/creatives/${id}${query}`;
    let response = null;
    if (this.isEnabled()) {
      try {
        response = await this.performLivestoreRequest(action, { method: 'DELETE' });
      } catch (error) {
        console.warn('LiveStore: failed to delete creative from LiveStore', error);
        response = null;
      }
      if (response) {
        await this.handleResponseCaching(response.clone(), 'DELETE', action);
        this.enqueueServerDestroy(action);
        return response;
      }
    }
    const serverResponse = await this.performServerRequest(action, 'DELETE');
    await this.handleResponseCaching(serverResponse.clone(), 'DELETE', action);
    return serverResponse;
  }

  enqueueServerSync(action, method, form) {
    schedule(() => {
      const formData = new FormData(form);
      return this.performServerRequest(action, method, formData)
        .then((response) => this.handleResponseCaching(response.clone(), method, action))
        .catch((error) => console.error('LiveStore: failed to sync creative with server', error));
    });
  }

  enqueueServerDestroy(action) {
    schedule(() => {
      return this.performServerRequest(action, 'DELETE')
        .then((response) => this.handleResponseCaching(response.clone(), 'DELETE', action))
        .catch((error) => console.error('LiveStore: failed to sync creative deletion with server', error));
    });
  }

  async refreshFromServer(id) {
    if (!id) return null;
    try {
      const response = await fetch(`/creatives/${id}.json`, { credentials: 'same-origin' });
      if (response.status === 404) {
        this.removeCachedCreative(id);
        return null;
      }
      if (!response.ok) return null;
      const data = await response.json();
      return this.cacheCreative(data);
    } catch (error) {
      console.warn('LiveStore: failed to refresh creative from server', error);
      return null;
    }
  }
}

const livestoreClient = new LivestoreClient(LIVESTORE_BASE_URL, storage);
export default livestoreClient;
