window.Jails = {
  components: {},
  instances: {},
  component: function(name, factory) {
    this.components[name] = factory;
  },
  mount: function() {
    var self = this;
    document.querySelectorAll('[data-component]').forEach(function(el) {
      var name = el.dataset.component;
      var factory = self.components[name];
      if (factory) {
        var instance = factory(el) || {};
        self.instances[name] = instance;
        if (typeof instance.mount === 'function') { instance.mount(); }
        else if (typeof instance.init === 'function') { instance.init(); }
      }
    });
  },
  get: function(name) {
    return this.instances[name];
  }
};
