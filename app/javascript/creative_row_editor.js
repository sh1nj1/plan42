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
    const closeBtn = document.getElementById('inline-close');

    let currentTree = null;
    let saveTimer = null;
    let pendingSave = false;

    function hideRow(tree) {
      const row = tree.querySelector('.creative-row');
      if (row) row.style.display = 'none';
    }

    function showRow(tree) {
      const row = tree.querySelector('.creative-row');
      if (row) row.style.display = '';
    }

    function refreshRow(tree) {
      const id = tree.id.replace('creative-', '');
      fetch(`/creatives/${id}.json`)
        .then(r => r.json())
        .then(data => {
          const link = tree.querySelector('a.unstyled-link');
          if (link) link.innerHTML = data.description || '';
          const span = tree.querySelector('.creative-row-end span');
          if (span) {
            span.textContent = `${Math.round((data.progress || 0) * 100)}%`;
            span.className = data.progress == 1 ?
              'creative-progress-complete' : 'creative-progress-incomplete';
          }
        });
    }

    function saveForm() {
      clearTimeout(saveTimer);
      pendingSave = false;
      if (!form.action) return Promise.resolve();
      return fetch(form.action, {
        method: 'PATCH',
        headers: {
          'Accept': 'application/json',
          'X-CSRF-Token': document.querySelector('meta[name="csrf-token"]').content
        },
        body: new FormData(form),
        credentials: 'same-origin'
      });
    }

    function hideCurrent() {
      if (!currentTree) return;
      const tree = currentTree;
      currentTree = null;
      template.style.display = 'none';
      saveForm().then(() => {
        showRow(tree);
        refreshRow(tree);
      });
    }

    function attachButtons() {
      document.querySelectorAll('.edit-inline-btn').forEach(function(btn) {
        const tree = btn.closest('.creative-tree');
        if (!tree) return;
        btn.addEventListener('click', function(e) {
          e.preventDefault();
          if (currentTree === tree) {
            hideCurrent();
            return;
          }
          if (currentTree) {
            hideCurrent();
          }
          currentTree = tree;
          hideRow(tree);
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
          editor.focus();
        });
    }

    function move(delta) {
      if (!currentTree) return;
      const trees = Array.from(document.querySelectorAll('.creative-tree'));
      const index = trees.indexOf(currentTree);
      if (index === -1) return;
      const target = trees[index + delta];
      if (!target) return;
      const prev = currentTree;
      currentTree = target;
      hideRow(target);
      target.appendChild(template);
      template.style.display = 'block';
      saveForm().then(() => {
        showRow(prev);
        refreshRow(prev);
      });
      loadCreative(target.id.replace('creative-', ''));
    }

    function scheduleSave() {
      pendingSave = true;
      clearTimeout(saveTimer);
      saveTimer = setTimeout(saveForm, 5000);
    }

    progressInput.addEventListener('input', function() {
      progressValue.textContent = progressInput.value;
      scheduleSave();
    });
    editor.addEventListener('trix-change', scheduleSave);

    editor.addEventListener('keydown', function(e) {
      if (e.key !== 'ArrowUp' && e.key !== 'ArrowDown') return;
      const range = editor.editor.getSelectedRange();
      if (!range) return;
      const start = range[0];
      const end = range[1];
      const length = editor.editor.getDocument().toString().length;
      if (e.key === 'ArrowUp' && start === 0 && end === 0) {
        e.preventDefault();
        if (pendingSave) saveForm();
        move(-1);
      } else if (e.key === 'ArrowDown' && start >= length - 1 && end >= length - 1) {
        e.preventDefault();
        if (pendingSave) saveForm();
        move(1);
      }
    });

    if (closeBtn) {
      closeBtn.addEventListener('click', hideCurrent);
    }

    upBtn.addEventListener('click', function() {
      if (pendingSave) saveForm();
      move(-1);
    });
    downBtn.addEventListener('click', function() {
      if (pendingSave) saveForm();
      move(1);
    });

    attachButtons();
  });
}
