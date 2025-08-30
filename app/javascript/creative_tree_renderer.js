if (!window.creativeTreeRenderer) {
  window.creativeTreeRenderer = {
    renderNode(node) {
      const row = document.createElement('div');
      row.className = 'creative-row';
      const content = document.createElement('div');
      content.className = 'creative-content';
      content.innerHTML = node.description;
      row.appendChild(content);
      if (node.children && node.children.length > 0) {
        const children = document.createElement('div');
        children.className = 'creative-children';
        node.children.forEach(child => {
          children.appendChild(this.renderNode(child));
        });
        row.appendChild(children);
      }
      return row;
    },
    renderTree(data, container) {
      container.innerHTML = '';
      data.forEach(node => container.appendChild(this.renderNode(node)));
    },
    init() {
      const container = document.getElementById('creatives');
      if (!container || !window.creativesApi) return;
      const parentId = container.dataset.parentId;
      window.creativesApi.tree(parentId)
        .then(data => this.renderTree(data, container));
    }
  };
  document.addEventListener('turbo:load', () => window.creativeTreeRenderer.init());
}
