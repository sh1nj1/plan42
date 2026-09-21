export function createListenerRegistry() {
  const bindings = [];

  return {
    add(target, type, handler, options) {
      if (!target || typeof target.addEventListener !== 'function') return;

      target.addEventListener(type, handler, options);
      bindings.push({ target, type, handler, options });
    },

    releaseAll() {
      while (bindings.length > 0) {
        const { target, type, handler, options } = bindings.pop();
        target.removeEventListener(type, handler, options);
      }
    },

    get size() {
      return bindings.length;
    },
  };
}
