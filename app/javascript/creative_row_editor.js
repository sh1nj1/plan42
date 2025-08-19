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
    const deleteBtn = document.getElementById('inline-delete');
    const deleteChildrenBtn = document.getElementById('inline-delete-with-children');

    const methodInput = document.getElementById('inline-method');
    const parentInput = document.getElementById('inline-parent-id');
    const beforeInput = document.getElementById('inline-before-id');
    const afterInput = document.getElementById('inline-after-id');
    const childInput = document.getElementById('inline-child-id');

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
      clearTimeout(saveTimer);
      const method = methodInput.value === 'patch' ? 'PATCH' : 'POST';
      pendingSave = false;
      if (!form.action) return Promise.resolve();
      return fetch(form.action, {
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
            if (tree) tree.id = `creative-${data.id}`;
            const parentTree = parentId ? document.getElementById(`creative-${parentId}`) : null;
            if (parentTree) {
              refreshChildren(parentTree);
            } else {
              location.reload();
            }
          } else if (method === 'PATCH') {
            if (tree) refreshRow(tree);
          }
        });
      });
    }

    function hideCurrent() {
      if (!currentTree) return;
      const tree = currentTree;
      const wasNew = !form.dataset.creativeId;
      currentTree = null;
      template.style.display = 'none';
      const p = pendingSave ? saveForm() : Promise.resolve();
      p.then(() => {
        if (wasNew && !form.dataset.creativeId) {
          tree.remove();
        } else {
          showRow(tree);
          refreshRow(tree);
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
            hideCurrent();
          }
          currentTree = tree;
          hideRow(tree);
          tree.appendChild(template);
          template.style.display = 'block';
          loadCreative(tree.id.replace('creative-', ''));
        });
      });

      document.querySelectorAll('.add-creative-btn').forEach(function(btn) {
        btn.addEventListener('click', function(e) {
          e.preventDefault();
          const tree = btn.closest('.creative-tree');
          let parentId, container, insertBefore, beforeId = '';
          if (tree) {
            parentId = tree.id.replace('creative-', '');
            container = tree.querySelector('.creative-children');
            if (!container) {
              container = document.createElement('div');
              container.className = 'creative-children';
              container.id = 'creative-children-' + parentId;
              tree.appendChild(container);
            }
            insertBefore = container.firstElementChild;
            beforeId = insertBefore ? insertBefore.id.replace('creative-', '') : '';
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
            beforeId = insertBefore ? insertBefore.id.replace('creative-', '') : '';
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
          const beforeId = insertBefore ? insertBefore.id.replace('creative-', '') : '';
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
          if (deleteBtn) deleteBtn.style.display = '';
          if (deleteChildrenBtn) deleteChildrenBtn.style.display = '';
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
      const p = pendingSave ? saveForm(prev, prevParent) : Promise.resolve();
      p.then(() => {
        if (wasNew && !form.dataset.creativeId) {
          prev.remove();
        } else {
          showRow(prev);
          refreshRow(prev);
        }
      });
      loadCreative(target.id.replace('creative-', ''));
    }

    function addNew() {
      if (!currentTree) return;
      const prev = currentTree;
      const wasNew = !form.dataset.creativeId;
      const prevParent = parentInput.value;
      const prevCreativeId = prev.id.replace('creative-', '')
      const childContainer = prev.parentElement.querySelector('#creative-children-' + prevCreativeId);
      const firstChild = childContainer && childContainer.querySelector('.creative-tree');
      let parentId, container, insertBefore,
          beforeId = '', afterId = '';
      if (firstChild) {
        parentId = prevCreativeId;
        container = childContainer;
        insertBefore = firstChild;
        beforeId = firstChild.id.replace('creative-', '');
      } else {
        parentId = prev.parentElement?.id?.startsWith("creative-children-") ? prev.parentElement.id.replace('creative-children-', '') : null;
        container = prev.parentNode;
        afterId = prev.id.replace('creative-', '');
        insertBefore = prev.nextSibling;
      }
      const p = pendingSave ? saveForm(prev, prevParent) : Promise.resolve();
      p.then(() => {
        if (wasNew && !form.dataset.creativeId) {
          prev.remove();
        } else {
          showRow(prev);
          refreshRow(prev);
        }
      });
      const newTree = document.createElement('div');
      newTree.className = 'creative-tree';
      if (insertBefore) container.insertBefore(newTree, insertBefore); else container.appendChild(newTree);
      currentTree = newTree;
      newTree.appendChild(template);
      template.style.display = 'block';
      form.action = '/creatives';
      methodInput.value = '';
      form.dataset.creativeId = '';
      parentInput.value = parentId;
      beforeInput.value = beforeId;
      afterInput.value = afterId;
      if (childInput) childInput.value = '';
      descriptionInput.value = '';
      editor.editor.loadHTML('');
      progressInput.value = 0;
      progressValue.textContent = 0;
      pendingSave = false;
      editor.focus();
    }

    function startNew(parentId, container, insertBefore, beforeId = '', afterId = '', childId = '') {
      if (currentTree) hideCurrent();
      const newTree = document.createElement('div');
      newTree.className = 'creative-tree';
      if (insertBefore) container.insertBefore(newTree, insertBefore); else container.appendChild(newTree);
      currentTree = newTree;
      newTree.appendChild(template);
      template.style.display = 'block';
      form.action = '/creatives';
      methodInput.value = '';
      form.dataset.creativeId = '';
      if (deleteBtn) deleteBtn.style.display = 'none';
      if (deleteChildrenBtn) deleteChildrenBtn.style.display = 'none';
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

    if (deleteBtn) {
      deleteBtn.addEventListener('click', function() {
        if (!form.dataset.creativeId) return;
        if (!confirm(deleteBtn.dataset.confirm)) return;
        const parentId = parentInput.value || '';
        const container = currentTree.parentNode;
        const insertBefore = currentTree.nextSibling;
        const beforeId = insertBefore ? insertBefore.id.replace('creative-', '') : '';
        const prev = currentTree.previousSibling;
        const afterId = !beforeId && prev ? prev.id.replace('creative-', '') : '';
        fetch(`/creatives/${form.dataset.creativeId}`, {
          method: 'DELETE',
          headers: { 'X-CSRF-Token': document.querySelector('meta[name="csrf-token"]').content }
        }).then(function(r) {
          if (!r.ok) return;
          const parentTree = parentId ? document.getElementById(`creative-${parentId}`) : null;
          currentTree.remove();
          startNew(parentId, container, insertBefore, beforeId, afterId);
          if (parentTree) refreshRow(parentTree);
        });
      });
    }

    if (deleteChildrenBtn) {
      deleteChildrenBtn.addEventListener('click', function() {
        if (!form.dataset.creativeId) return;
        if (!confirm(deleteChildrenBtn.dataset.confirm)) return;
        const parentId = parentInput.value || '';
        const container = currentTree.parentNode;
        const insertBefore = currentTree.nextSibling;
        const beforeId = insertBefore ? insertBefore.id.replace('creative-', '') : '';
        const prev = currentTree.previousSibling;
        const afterId = !beforeId && prev ? prev.id.replace('creative-', '') : '';
        fetch(`/creatives/${form.dataset.creativeId}?delete_with_children=true`, {
          method: 'DELETE',
          headers: { 'X-CSRF-Token': document.querySelector('meta[name="csrf-token"]').content }
        }).then(function(r) {
          if (!r.ok) return;
          const parentTree = parentId ? document.getElementById(`creative-${parentId}`) : null;
          currentTree.remove();
          startNew(parentId, container, insertBefore, beforeId, afterId);
          if (parentTree) refreshRow(parentTree);
        });
      });
    }

    attachButtons();
  });
}
