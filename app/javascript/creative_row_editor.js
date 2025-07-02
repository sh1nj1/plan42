if (!window.creativeRowEditorInitialized) {
  window.creativeRowEditorInitialized = true;

  document.addEventListener('turbo:load', function() {
    const template = document.getElementById('inline-edit-form');
    if (!template) return;

    const form = document.getElementById('inline-edit-form-element');
    const descriptionInput = document.getElementById('inline-creative-description');
    const editor = template.querySelector('trix-editor');
    const progressInput = document.getElementById('inline-creative-progress');
    const progressValue = document.getElementById('inline-progress-value');
    const upBtn = document.getElementById('inline-move-up');
    const downBtn = document.getElementById('inline-move-down');

    let currentTree = null;
    let saveTimer = null;

    function attachButtons() {
      document.querySelectorAll('.edit-inline-btn').forEach(function(btn) {
        const tree = btn.closest('.creative-tree');
        if (!tree) return;
        btn.addEventListener('click', function(e) {
          e.preventDefault();
          currentTree = tree;
          tree.appendChild(template);
          template.style.display = 'block';
          loadCreative(tree.id.replace('creative-', ''));
        });
      });
    }

    function loadCreative(id) {
      fetch(`/creatives/${id}.json`)
        .then(r => r.json())
        .then(data => {
          form.action = `/creatives/${data.id}`;
          form.dataset.creativeId = data.id;
          descriptionInput.value = data.description || '';
          editor.editor.loadHTML(data.description || '');
          progressInput.value = data.progress || 0;
          progressValue.textContent = data.progress || 0;
        });
    }

    function move(delta) {
      if (!currentTree) return;
      const trees = Array.from(document.querySelectorAll('.creative-tree'));
      const index = trees.indexOf(currentTree);
      if (index === -1) return;
      const target = trees[index + delta];
      if (!target) return;
      currentTree = target;
      target.appendChild(template);
      loadCreative(target.id.replace('creative-', ''));
    }

    function scheduleSave() {
      clearTimeout(saveTimer);
      saveTimer = setTimeout(saveForm, 5000);
    }

    function saveForm() {
      clearTimeout(saveTimer);
      if (!form.action) return;
      fetch(form.action, {
        method: 'PATCH',
        headers: {
          'Accept': 'application/json',
          'X-CSRF-Token': document.querySelector('meta[name="csrf-token"]').content
        },
        body: new FormData(form),
        credentials: 'same-origin'
      });
    }

    progressInput.addEventListener('input', function() {
      progressValue.textContent = progressInput.value;
      scheduleSave();
    });
    editor.addEventListener('trix-change', scheduleSave);

    upBtn.addEventListener('click', function() {
      scheduleSave();
      move(-1);
    });
    downBtn.addEventListener('click', function() {
      scheduleSave();
      move(1);
    });

    attachButtons();
  });
}
