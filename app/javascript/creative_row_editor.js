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
    const addBtn = document.getElementById('inline-add');
    const closeBtn = document.getElementById('inline-close');

    const methodInput = document.getElementById('inline-method');
    const parentInput = document.getElementById('inline-parent-id');
    const beforeInput = document.getElementById('inline-before-id');
    const afterInput = document.getElementById('inline-after-id');
    const childInput = document.getElementById('inline-child-id');

    let currentTree = null;
    let saveTimer = null;
    let pendingSave = false;
    let saving = false;
    let savePromise = Promise.resolve();

    function hideRow(tree) {
      const row = tree.querySelector('.creative-row');
      if (row) row.style.display = 'none';
    }

    function showRow(tree) {
      const row = tree.querySelector('.creative-row');
      if (row) row.style.display = '';
    }

    function insertRow(tree, data) {
      if (tree.querySelector('.creative-row')) return;
      const row = document.createElement('div');
      row.className = 'creative-row';
      row.style.display = 'none';
      row.innerHTML = `
  <div class="creative-row-start">
    <div class="creative-row-actions">
      <button type="button" class="creative-action-btn add-creative-btn">+</button>
      <button type="button" class="creative-action-btn edit-inline-btn" data-creative-id="${data.id}">✎</button>
      <div class="creative-divider" style="width: 6px;"></div>
    </div>
    <a class="unstyled-link" href="/creatives/${data.id}">${data.description || ''}</a>
  </div>
  <div class="creative-row-end"><span class="creative-progress-incomplete">0%</span></div>`;
      tree.insertBefore(row, tree.firstChild);
      attachButtons();
    }

    function refreshRow(tree) {
      const id = tree.dataset.id;
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

    function refreshChildren(tree) {
      const container = tree.querySelector('.creative-children');
      if (!container) { location.reload(); return; }
      const url = container.dataset.loadUrl;
      if (!url) { location.reload(); return; }
      fetch(url)
        .then(r => r.text())
        .then(html => {
          container.innerHTML = html;
          attachButtons();
        });
    }

    function saveForm(tree = currentTree, parentId = parentInput.value) {
      if (saving) return savePromise;
      clearTimeout(saveTimer);
      const method = methodInput.value === 'patch' ? 'PATCH' : 'POST';
      pendingSave = false;
      if (!form.action) return Promise.resolve();
      saving = true;
      savePromise = fetch(form.action, {
        method: method,
        headers: {
          'Accept': 'application/json',
          'X-CSRF-Token': document.querySelector('meta[name="csrf-token"]').content
        },
        body: new FormData(form),
        credentials: 'same-origin'
      }).then(function(r) {
        if (!r.ok) return r;
        return r.text().then(function(text) {
          try { return text ? JSON.parse(text) : {}; } catch (e) { return {}; }
        }).then(function(data) {
          if (method === 'POST' && data.id) {
            form.action = `/creatives/${data.id}`;
            methodInput.value = 'patch';
            form.dataset.creativeId = data.id;
            if (tree) {
              tree.id = `creative-${data.id}`;
              tree.dataset.id = data.id;
              tree.dataset.parentId = parentId || '';
              insertRow(tree, data);
            }
            const parentTree = parentId ? document.getElementById(`creative-${parentId}`) : null;
            if (parentTree) refreshRow(parentTree);
          } else if (method === 'PATCH') {
            if (tree) refreshRow(tree);
          }
        });
      }).finally(function() {
        saving = false;
      });
      return savePromise;
    }

    function hideCurrent(reload = true) {
      if (!currentTree) return;
      const tree = currentTree;
      const parentId = parentInput.value;
      const wasNew = !form.dataset.creativeId;
      currentTree = null;
      template.style.display = 'none';
      const p = (pendingSave || saving) ? saveForm() : Promise.resolve();
      p.then(() => {
        if (wasNew && !form.dataset.creativeId) {
          tree.remove();
        } else if (!tree.querySelector('.creative-row')) {
          const parentTree = parentId ? document.getElementById(`creative-${parentId}`) : null;
          if (parentTree) {
            refreshChildren(parentTree);
          } else {
            if (reload) location.reload();
          }
        } else {
          showRow(tree);
          refreshRow(tree);
          if (reload) location.reload();
        }
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
            hideCurrent(false);
          }
          currentTree = tree;
          hideRow(tree);
          tree.appendChild(template);
          template.style.display = 'block';
          loadCreative(tree.dataset.id);
        });
      });

      document.querySelectorAll('.add-creative-btn').forEach(function(btn) {
        btn.addEventListener('click', function(e) {
          e.preventDefault();
          const tree = btn.closest('.creative-tree');
          let parentId, container, insertBefore, beforeId = '';
          if (tree) {
            parentId = tree.dataset.id;
            container = tree.querySelector('.creative-children');
            if (!container) {
              container = document.createElement('div');
              container.className = 'creative-children';
              container.id = 'creative-children-' + parentId;
              tree.appendChild(container);
            }
            insertBefore = container.firstElementChild;
            beforeId = insertBefore ? insertBefore.dataset.id : '';
          } else {
            parentId = btn.dataset.parentId || '';
            const parentTree = parentId ? document.getElementById('creative-' + parentId) : null;
            container = parentId ? document.getElementById('creative-children-' + parentId) : document.getElementById('creatives');
            if (!container) {
              container = document.createElement('div');
              container.className = parentTree ? 'creative-children' : '';
              if (parentTree) {
                container.id = 'creative-children-' + parentId;
                parentTree.appendChild(container);
              } else {
                document.getElementById('creatives').appendChild(container);
              }
            }
            insertBefore = container.firstElementChild;
            beforeId = insertBefore ? insertBefore.dataset.id : '';
          }
          startNew(parentId, container, insertBefore, beforeId);
        });
      });

      document.querySelectorAll('.new-root-creative-btn').forEach(function(btn) {
        const container = document.getElementById('creatives');
        if (!container) return;
        btn.addEventListener('click', function(e) {
          e.preventDefault();
          const insertBefore = container.firstElementChild;
          const beforeId = insertBefore ? insertBefore.dataset.id : '';
          startNew('', container, insertBefore, beforeId);
        });
      });

      document.querySelectorAll('.append-below-btn').forEach(function(btn) {
        btn.addEventListener('click', function(e) {
          e.preventDefault();
          const targetId = btn.dataset.targetId;
          const target = document.getElementById('creative-' + targetId);
          if (!target) return;
          const container = target.parentNode;
          const insertBefore = target.nextSibling;
          startNew(
            target.parentNode.id.startsWith('creative-children-') ? target.parentNode.id.replace('creative-children-', '') : '',
            container,
            insertBefore,
            '',
            targetId
          );
        });
      });

      document.querySelectorAll('.append-parent-btn').forEach(function(btn) {
        btn.addEventListener('click', function(e) {
          e.preventDefault();
          const targetId = btn.dataset.childId;
          const target = document.getElementById('creative-' + targetId);
          if (!target) return;
          const container = target.parentNode;
          startNew(
            container.id.startsWith('creative-children-') ? container.id.replace('creative-children-', '') : '',
            container,
            target,
            targetId,
            '',
            targetId
          );
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
          parentInput.value = data.parent_id || '';
          beforeInput.value = '';
          afterInput.value = '';
          if (childInput) childInput.value = '';
          editor.focus();
        });
    }

    function beforeNewOrMove(wasNew, prev, prevParent) {
        const needsSave = pendingSave || wasNew || saving;
        const p = needsSave ? saveForm(prev, prevParent) : Promise.resolve();
        return p.then(() => {
            if (wasNew && !form.dataset.creativeId) {
                prev.remove();
            } else {
                showRow(prev);
                refreshRow(prev);
            }
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
      const wasNew = !form.dataset.creativeId;
      const prevParent = parentInput.value;
      currentTree = target;
      hideRow(target);
      target.appendChild(template);
      template.style.display = 'block';
      beforeNewOrMove(wasNew, prev, prevParent).then(() => {
        loadCreative(target.dataset.id);
      });
    }

    function addNew() {
      if (!currentTree) return;
      const prev = currentTree;
      const wasNew = !form.dataset.creativeId;
      const prevParent = parentInput.value;
      beforeNewOrMove(wasNew, prev, prevParent).then(() => {
        const prevCreativeId = prev.dataset.id;
        const childContainer = document.getElementById('creative-children-' + prevCreativeId);
        const isCollapsed = childContainer && childContainer.style.display === 'none';
        const firstChild = childContainer && childContainer.querySelector('.creative-tree');
        let parentId, container, insertBefore,
            beforeId = '', afterId = '';
        if (firstChild && !isCollapsed) {
          parentId = prevCreativeId;
          container = childContainer;
          insertBefore = firstChild;
          beforeId = firstChild.dataset.id;
        } else {
          parentId = prev.dataset.parentId;
          container = prev.parentNode;
          afterId = prev.dataset.id;
          insertBefore = prev.nextSibling;
        }
        startNew(parentId, container, insertBefore, beforeId, afterId);
      });
    }

    function startNew(parentId, container, insertBefore, beforeId = '', afterId = '', childId = '') {
      if (currentTree) hideCurrent(false);
      const newTree = document.createElement('div');
      newTree.className = 'creative-tree';
      newTree.dataset.parentId = parentId || '';
      if (insertBefore) container.insertBefore(newTree, insertBefore); else container.appendChild(newTree);
      currentTree = newTree;
      newTree.appendChild(template);
      template.style.display = 'block';
      form.action = '/creatives';
      methodInput.value = '';
      form.dataset.creativeId = '';
      parentInput.value = parentId || '';
      beforeInput.value = beforeId || '';
      afterInput.value = afterId || '';
      if (childInput) childInput.value = childId || '';
      descriptionInput.value = '';
      editor.editor.loadHTML('');
      progressInput.value = 0;
      progressValue.textContent = 0;
      pendingSave = false;
      editor.focus();
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
      if (e.key === 'Escape') {
        e.preventDefault();
        hideCurrent();
        return;
      }
      if (e.key === 'Enter' && e.shiftKey) {
        e.preventDefault();
        addNew();
        return;
      }
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

    if (addBtn) {
      addBtn.addEventListener('click', addNew);
    }

    attachButtons();
  });
}
