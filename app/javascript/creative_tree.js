if (!window.creativeTreeInitialized) {
  window.creativeTreeInitialized = true;

  document.addEventListener('turbo:load', function () {
    const container = document.getElementById('creative-tree');
    if (!container) return;

    const url = window.location.pathname + '.json' + window.location.search;
    fetch(url)
      .then(r => r.json())
      .then(data => {
        container.appendChild(buildList(data));
      });

    function buildList(nodes) {
      const ul = document.createElement('ul');
      nodes.forEach(node => {
        const li = document.createElement('li');
        li.innerHTML = node.description || '';
        if (node.children && node.children.length > 0) {
          li.appendChild(buildList(node.children));
        }
        ul.appendChild(li);
      });
      return ul;
    }
  });
}
