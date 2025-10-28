import creativesApi from './lib/api/creatives'

if (!window.creativeRowEditorInitialized) {
  window.creativeRowEditorInitialized = true;

  document.addEventListener('turbo:load', function() {
    const template = document.getElementById('inline-edit-form');
    if (!template) return;

    initializeEventListeners();

    const form = document.getElementById('inline-edit-form-element');
    const descriptionInput = document.getElementById('inline-creative-description');
    const editor = template.querySelector('trix-editor');
    const progressInput = document.getElementById('inline-creative-progress');
    const progressValue = document.getElementById('inline-progress-value');
    const upBtn = document.getElementById('inline-move-up');
    const downBtn = document.getElementById('inline-move-down');
    const addBtn = document.getElementById('inline-add');
    const addChildBtn = document.getElementById('inline-add-child');
    const deleteBtn = document.getElementById('inline-delete');
    const deleteWithChildrenBtn = document.getElementById('inline-delete-with-children');
    const linkBtn = document.getElementById('inline-link');
    const unlinkBtn = document.getElementById('inline-unlink');
    const unconvertBtn = document.getElementById('inline-unconvert');
    const closeBtn = document.getElementById('inline-close');
    const parentSuggestions = document.getElementById('parent-suggestions');
    const parentSuggestBtn = document.getElementById('inline-recommend-parent');
    const linkModal = document.getElementById('link-creative-modal');
    const linkSearchInput = document.getElementById('link-creative-search');
    const linkResults = document.getElementById('link-creative-results');
    const linkCloseBtn = document.getElementById('close-link-creative-modal');

    const methodInput = document.getElementById('inline-method');
    const parentInput = document.getElementById('inline-parent-id');
    const beforeInput = document.getElementById('inline-before-id');
    const afterInput = document.getElementById('inline-after-id');
    const childInput = document.getElementById('inline-child-id');

    let currentTree = null;
    let currentRowElement = null;
    let saveTimer = null;
    let pendingSave = false;
    let saving = false;
    let savePromise = Promise.resolve();
    let autoLinking = false;

    function treeRowElement(node) {
      return node && node.closest ? node.closest('creative-tree-row') : null;
    }

    function treeContainerElement(tree) {
      if (!tree) return null;
      const row = treeRowElement(tree);
      if (row && row.parentNode) return row.parentNode;
      return tree.parentNode;
    }

    function nodeAfterTreeBlock(tree) {
      if (!tree) return null;
      const row = treeRowElement(tree);
      if (!row) return tree.nextSibling;
      let node = row.nextSibling;
      while (node && node.nodeType === Node.TEXT_NODE) node = node.nextSibling;
      const treeId = tree.dataset?.id;
      if (treeId) {
        const childrenContainer = document.getElementById(`creative-children-${treeId}`);
        if (childrenContainer && childrenContainer.parentNode === row.parentNode && node === childrenContainer) {
          node = childrenContainer.nextSibling;
          while (node && node.nodeType === Node.TEXT_NODE) node = node.nextSibling;
        }
      }
      return node;
    }

    function normalizeRowNode(node) {
      if (!node) return null;
      if (node.matches && node.matches('creative-tree-row')) return node;
      if (node.classList && node.classList.contains('creative-tree')) {
        const row = treeRowElement(node);
        return row || node;
      }
      return node;
    }

    function readRowLevel(row) {
      if (!row) return null;
      if (row.isTitle) return 0;
      if (row.getAttribute) {
        const levelAttr = row.getAttribute('level');
        if (levelAttr) {
          const parsed = Number(levelAttr);
          if (!Number.isNaN(parsed)) return parsed;
        }
      }
      if (typeof row.level === 'number') {
        return row.level;
      }
      if (row.level) {
        const parsed = Number(row.level);
        if (!Number.isNaN(parsed)) return parsed;
      }
      const tree = row.querySelector ? row.querySelector('.creative-tree') : null;
      if (tree && tree.dataset?.level) {
        const parsed = Number(tree.dataset.level);
        if (!Number.isNaN(parsed)) return parsed;
      }
      return 1;
    }

    function computeNewRowLevel(parentId, referenceNode, afterId) {
      if (parentId) {
        const parentRow = document.querySelector(`creative-tree-row[creative-id="${parentId}"]`);
        if (parentRow) {
          return readRowLevel(parentRow) + 1;
        }
        const parentTree = document.getElementById(`creative-${parentId}`);
        if (parentTree?.dataset?.level) {
          const parsed = Number(parentTree.dataset.level);
          if (!Number.isNaN(parsed)) return parsed + 1;
        }
        console.log('use default level 2')
        return 2;
      }
      const normalized = normalizeRowNode(referenceNode) || (afterId ? treeRowElement(document.getElementById(`creative-${afterId}`)) : null);
      return readRowLevel(normalized);
    }

    function removeTreeElement(tree) {
      if (!tree) return;
      const row = treeRowElement(tree);
      if (row) {
        row.remove();
      } else if (tree.remove) {
        tree.remove();
      }
    }

    function handleEditButtonClick(tree) {
      if (!tree) return;

      if (currentTree === tree) {
        hideCurrent();
        return;
      }
      if (currentTree) {
        hideCurrent(false);
      }
      currentTree = tree;
      currentRowElement = treeRowElement(tree);
      hideRow(tree);
      tree.draggable = false;
      tree.appendChild(template);
      template.style.display = 'block';
      loadCreative(tree.dataset.id);
    }

    function initializeEventListeners() {
      if (!window._creativeEditClickHandler) {
        window._creativeEditClickHandler = function(e) {
          const tree = e.detail?.treeElement || e.detail?.button?.closest('.creative-tree');
          if (!tree) return;
          e.preventDefault();
          handleEditButtonClick(tree);
        };
        document.addEventListener('creative-edit-click', window._creativeEditClickHandler);
      }

      document.body.addEventListener('click', function(e) {
        // Delegated event for .edit-inline-btn
        const editBtn = e.target.closest('.edit-inline-btn');
        if (editBtn) {
          e.preventDefault();
          const tree = editBtn.closest('.creative-tree');
          if (!tree) return;
          handleEditButtonClick(tree);
          return; // Event handled
        }

        // Delegated event for .add-creative-btn
        const addBtn = e.target.closest('.add-creative-btn:not(#inline-add):not(#inline-add-child)');
        if (addBtn) {
          e.preventDefault();
          if (template.style.display === 'block') {
            hideCurrent();
            return;
          }
          const tree = addBtn.closest('.creative-tree');
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
            beforeId = insertBefore ? creativeIdFrom(insertBefore) : '';
          } else {
            parentId = addBtn.dataset.parentId || '';
            const rootContainer = document.getElementById('creatives');
            container = rootContainer;
            insertBefore = rootContainer.firstElementChild;
            beforeId = insertBefore ? creativeIdFrom(insertBefore) : '';
          }
          startNew(parentId, container, insertBefore, beforeId);
          return; // Event handled
        }

        // Delegated event for .new-root-creative-btn
        const newRootBtn = e.target.closest('.new-root-creative-btn');
        if (newRootBtn) {
          e.preventDefault();
          const container = document.getElementById('creatives');
          if (!container) return;

          if (template.style.display === 'block') {
            hideCurrent();
            return;
          }
          const insertBefore = container.firstElementChild;
          const beforeId = insertBefore ? creativeIdFrom(insertBefore) : '';
          startNew('', container, insertBefore, beforeId);
          return; // Event handled
        }

        // Delegated event for .append-parent-btn
        const appendParentBtn = e.target.closest('.append-parent-btn');
        if (appendParentBtn) {
          e.preventDefault();
          const targetId = appendParentBtn.dataset.childId;
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
          return; // Event handled
        }
      });
    }

    function hideRow(tree) {
      const row = tree.querySelector('.creative-row');
      if (row) row.style.display = 'none';
    }

    function showRow(tree) {
      const row = tree.querySelector('.creative-row');
      if (row) row.style.display = '';
    }

    function creativeTreeElement(node) {
      if (!node) return null;
      if (node.classList && node.classList.contains('creative-tree')) return node;
      if (node.querySelector) {
        const inner = node.querySelector('.creative-tree');
        if (inner) return inner;
      }
      return null;
    }

    function creativeIdFrom(node) {
      const treeEl = creativeTreeElement(node);
      if (treeEl && treeEl.dataset) {
        return treeEl.dataset.id || '';
      }
      if (node?.getAttribute) {
        return node.getAttribute('creative-id') || node.getAttribute('data-id') || '';
      }
      return '';
    }

    function insertRow(tree, data) {
      if (tree.querySelector('.creative-row')) return;
      const row = document.createElement('div');
      row.className = 'creative-row';
      row.style.display = 'none';
      // TODO: remove DRY, use template or copy existing dom
      row.innerHTML = `
  <div class="creative-row-start">
    <div class="creative-row-actions">
      <button type="button" class="creative-action-btn edit-inline-btn" data-creative-id="${data.id}">
        <!-- ok -->
      </button>
      <div class="creative-divider" style="width: 6px;"></div>
    </div>
    <a class="unstyled-link" href="/creatives/${data.id}">${data.description || ''}</a>
  </div>
  <div class="creative-row-end"><span class="creative-progress-incomplete">0%</span></div>`;
      tree.insertBefore(row, tree.firstChild);
    }

    function refreshRow(tree) {
      const id = tree.dataset.id;
      creativesApi.get(id)
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
      if (!container) { location.reload(); return Promise.resolve(); }
      const url = container.dataset.loadUrl;
      if (!url) { location.reload(); return Promise.resolve(); }
      return creativesApi.loadChildren(url)
        .then(html => {
          container.innerHTML = html;
        });
    }

    function saveForm(tree = currentTree, parentId = parentInput.value) {
      if (saving) return savePromise;
      clearTimeout(saveTimer);
      const method = methodInput.value === 'patch' ? 'PATCH' : 'POST';
      pendingSave = false;
      if (!form.action) return Promise.resolve();
      saving = true;
      const original = descriptionInput.value;
      descriptionInput.value = original
            .replace(/data-trix-attachment/g, 'trix-data-attachment')
            .replace(/data-trix-attributes/g, 'trix-data-attributes');
      savePromise = creativesApi.save(form.action, method, form).then(function(r) {
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
              const rowEl = treeRowElement(tree) || currentRowElement;
              if (rowEl) {
                rowEl.setAttribute('creative-id', data.id);
                rowEl.creativeId = data.id;
                const levelValue = tree.dataset.level;
                if (levelValue) {
                  rowEl.setAttribute('level', levelValue);
                  rowEl.level = Number(levelValue);
                }
                if (parentId) {
                  rowEl.setAttribute('parent-id', parentId);
                  rowEl.parentId = parentId;
                  rowEl.removeAttribute('is-root');
                  rowEl.isRoot = false;
                } else {
                  rowEl.removeAttribute('parent-id');
                  rowEl.parentId = null;
                  rowEl.setAttribute('is-root', '');
                  rowEl.isRoot = true;
                }
                rowEl.canWrite = true;
                rowEl.setAttribute('can-write', '');
                rowEl.requestUpdate?.();
              }
              insertRow(tree, data);
            }
            const parentTree = parentId ? document.getElementById(`creative-${parentId}`) : null;
            if (parentTree) refreshRow(parentTree);
          } else if (method === 'PATCH') {
            if (tree) refreshRow(tree);
          }
        });
      }).finally(function() {
        descriptionInput.value = original;
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
      currentRowElement = null;
      tree.draggable = true;
      template.style.display = 'none';
      const p = (pendingSave || saving) ? saveForm() : Promise.resolve();
      p.then(() => {
        if (wasNew && !form.dataset.creativeId) {
          removeTreeElement(tree);
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
      // Most button attachments are now handled by event delegation in initializeEventListeners.
      // We only need to handle comment buttons here, if that function exists.
      if (window.attachCommentButtons) window.attachCommentButtons();
    }
    window.attachCreativeRowEditorButtons = attachButtons;

    function loadCreative(id) {
      creativesApi.get(id)
        .then(data => {
          form.action = `/creatives/${data.id}`;
          form.dataset.creativeId = data.id;
          let content = data.description || '';
          content = content
                .replace(/trix-data-attachment/g, 'data-trix-attachment')
                .replace(/trix-data-attributes/g, 'data-trix-attributes');
          descriptionInput.value = content;
          editor.editor.loadHTML(content);
          progressInput.value = data.progress || 0;
          progressValue.textContent = data.progress || 0;
          parentInput.value = data.parent_id || '';
          beforeInput.value = '';
          afterInput.value = '';
          if (childInput) childInput.value = '';
          if (linkBtn) linkBtn.style.display = data.origin_id ? 'none' : '';
          if (unlinkBtn) unlinkBtn.style.display = data.origin_id ? '' : 'none';
          if (unconvertBtn) unconvertBtn.style.display = data.parent_id ? '' : 'none';
          editor.focus();
        });
    }

    function beforeNewOrMove(wasNew, prev, prevParent) {
        const needsSave = pendingSave || wasNew || saving;
        const p = needsSave ? saveForm(prev, prevParent) : Promise.resolve();
        return p.then(() => {
            if (wasNew && !form.dataset.creativeId) {
                removeTreeElement(prev);
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
      currentRowElement = treeRowElement(target);
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
          insertBefore = normalizeRowNode(firstChild);
          beforeId = insertBefore ? creativeIdFrom(insertBefore) : '';
        } else {
          parentId = prev.dataset.parentId;
          container = treeContainerElement(prev);
          afterId = prev.dataset.id;
          insertBefore = nodeAfterTreeBlock(prev);
        }
        startNew(parentId, container, insertBefore, beforeId, afterId);
      });
    }

    function addChild() {
      if (!currentTree) return;
      const prev = currentTree;
      const wasNew = !form.dataset.creativeId;
      const prevParent = parentInput.value;
      beforeNewOrMove(wasNew, prev, prevParent).then(() => {
        const parentId = prev.dataset.id;
        let container = document.getElementById('creative-children-' + parentId);
        if (!container) {
          container = document.createElement('div');
          container.className = 'creative-children';
          container.id = 'creative-children-' + parentId;
          prev.appendChild(container);
        }
        const insertBefore = container.firstElementChild;
        const beforeId = insertBefore ? creativeIdFrom(insertBefore) : '';
        startNew(parentId, container, insertBefore, beforeId);
      });
    }

    function deleteCurrent(withChildren) {
      if (!currentTree || !form.dataset.creativeId) return;
      const id = form.dataset.creativeId;
      const tree = currentTree;
      const trees = Array.from(document.querySelectorAll('.creative-tree'));
      const index = trees.indexOf(tree);
      const nextId = trees[index + 1] ? trees[index + 1].dataset.id : null;
      const parentId = tree.dataset.parentId;
      creativesApi.destroy(id, withChildren).then(() => {
        const parentTree = parentId ? document.getElementById(`creative-${parentId}`) : null;
        const childrenTree = document.getElementById("creative-children-" + id)
        if (!withChildren && childrenTree && parentTree) {
          refreshChildren(parentTree).then(() => {
            if (parentTree) refreshRow(parentTree);
          });
        } else {
          document.getElementById("creative-children-" + id)?.remove();
        }
        move(1);
        removeTreeElement(tree);
      });
    }

    function linkExistingCreative() {
      if (!currentTree || !form.dataset.creativeId || !linkModal || !linkSearchInput || !linkResults) return;
      linkModal.dataset.context = 'creative-link';
      linkModal.style.display = 'flex';
      document.body.classList.add('no-scroll');
      linkSearchInput.value = '';
      linkResults.innerHTML = '';
      linkSearchInput.focus();
    }

    function closeLinkModal() {
      if (!linkModal) return;
      linkModal.style.display = 'none';
      document.body.classList.remove('no-scroll');
      delete linkModal.dataset.context;
      linkModal.dispatchEvent(new CustomEvent('link-creative-modal:closed'));
    }

    function searchLinkCreatives() {
      const query = linkSearchInput.value.trim();
      if (!query) {
        linkResults.innerHTML = '';
        return;
      }
      fetch(`/creatives.json?search=${encodeURIComponent(query)}&simple=true`)
        .then(r => r.json())
        .then(results => {
          linkResults.innerHTML = '';
          if (Array.isArray(results)) {
            results.forEach(function(c) {
              const li = document.createElement('li');
              li.textContent = c.description;
              li.dataset.id = c.id;
              li.tabIndex = 0;
              li.setAttribute('role', 'button');
              linkResults.appendChild(li);
            });
          }
        });
    }

    function linkCreativeFromLi(li) {
      if (!linkModal) return;
      if (linkModal.dataset.context === 'comment-move') {
        linkModal.dispatchEvent(new CustomEvent('link-creative-modal:select', {
          detail: {
            id: li.dataset.id,
            label: li.textContent
          }
        }));
        closeLinkModal();
        return;
      }
      const fd = new FormData();
      fd.append('creative[parent_id]', form.dataset.creativeId);
      fd.append('creative[origin_id]', li.dataset.id);
      fd.append('authenticity_token', document.querySelector('meta[name="csrf-token"]').content);
      fetch('/creatives', {
        method: 'POST',
        headers: { 'Accept': 'application/json' },
        body: fd,
        credentials: 'same-origin'
      }).then(() => {
        closeLinkModal();
        refreshChildren(currentTree).then(() => refreshRow(currentTree));
      });
    }

    function handleLinkResultClick(e) {
      const li = e.target.closest('li');
      if (!li) return;
      linkCreativeFromLi(li);
    }

    function handleLinkResultKeydown(e) {
      if (e.key !== 'Enter') return;
      const li = e.target.closest('li');
      if (!li) return;
      e.preventDefault();
      linkCreativeFromLi(li);
    }

    function startNew(parentId, container, insertBefore, beforeId = '', afterId = '', childId = '') {
      if (currentTree) hideCurrent(false);

      let targetContainer = container || document.getElementById('creatives');
      if (targetContainer && targetContainer.matches && targetContainer.matches('creative-tree-row')) {
        targetContainer = targetContainer.parentNode;
      } else if (targetContainer && targetContainer.classList && targetContainer.classList.contains('creative-tree')) {
        const resolved = treeContainerElement(targetContainer);
        if (resolved) targetContainer = resolved;
      }

      let referenceNode = insertBefore;
      if (referenceNode && referenceNode.classList && referenceNode.classList.contains('creative-tree')) {
        const normalized = normalizeRowNode(referenceNode);
        if (normalized) referenceNode = normalized;
      }

      const level = computeNewRowLevel(parentId, referenceNode, afterId);

      const rowComponent = document.createElement('creative-tree-row');
      rowComponent.level = level;
      rowComponent.setAttribute('level', level);
      const iconSource = document.querySelector('creative-tree-row[data-edit-icon-html]');
      if (iconSource) {
        if (iconSource.dataset.editIconHtml) rowComponent.dataset.editIconHtml = iconSource.dataset.editIconHtml;
        if (iconSource.dataset.editOffIconHtml) rowComponent.dataset.editOffIconHtml = iconSource.dataset.editOffIconHtml;
      }
      if (parentId) {
        rowComponent.parentId = parentId;
        rowComponent.setAttribute('parent-id', parentId);
        rowComponent.removeAttribute('is-root');
        rowComponent.isRoot = false;
      } else {
        rowComponent.parentId = null;
        rowComponent.setAttribute('is-root', '');
        rowComponent.isRoot = true;
      }
      rowComponent.canWrite = true;
      rowComponent.setAttribute('can-write', '');
      rowComponent.hasChildren = false;
      rowComponent.removeAttribute('has-children');
      rowComponent.expanded = true;
      rowComponent.setAttribute('expanded', '');
      rowComponent.dataset.descriptionHtml = '';
      rowComponent.dataset.progressHtml = '';

      if (referenceNode) {
        targetContainer.insertBefore(rowComponent, referenceNode);
      } else {
        targetContainer.appendChild(rowComponent);
      }

      const finalizeSetup = () => {
        const newTree = rowComponent.querySelector('.creative-tree');
        if (!newTree || currentTree === newTree) return;
        newTree.dataset.parentId = parentId || '';
        newTree.dataset.level = String(level);
        newTree.draggable = false;
        hideRow(newTree);
        if (parentId) {
          const parentRow = document.querySelector(`creative-tree-row[creative-id="${parentId}"]`);
          if (parentRow) {
            parentRow.setAttribute('has-children', '');
            parentRow.hasChildren = true;
            parentRow.requestUpdate?.();
          }
        }
        currentTree = newTree;
        currentRowElement = rowComponent;
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
        if (linkBtn) linkBtn.style.display = '';
        if (unlinkBtn) unlinkBtn.style.display = 'none';
        if (unconvertBtn) unconvertBtn.style.display = 'none';
        pendingSave = false;
        editor.focus();
        if (parentSuggestions) {
          parentSuggestions.style.display = 'none';
          parentSuggestions.innerHTML = '';
        }
      };

      if (rowComponent.updateComplete) {
        rowComponent.updateComplete.then(finalizeSetup);
      } else {
        requestAnimationFrame(finalizeSetup);
      }
    }

    function scheduleSave() {
      pendingSave = true;
      clearTimeout(saveTimer);
      saveTimer = setTimeout(saveForm, 5000);
    }

    function autoLinkUrls(event) {
      if (autoLinking) return;

      const element = event.target;
      const editorInstance = element.editor;
      if (!editorInstance) return;

      const html = element.innerHTML;
      const linkedHtml = html.replace(/(^|\s)(https?:\/\/[^\s<]+)/g, function(_match, prefix, url) {
        return `${prefix}<a href="${url}" target="_blank" rel="noopener">${url}</a>`;
      });
      if (linkedHtml !== html) {
        const selection = editorInstance.getSelectedRange();
        autoLinking = true;
        try {
          editorInstance.loadHTML(linkedHtml);
          editorInstance.setSelectedRange(selection);
        } finally {
          requestAnimationFrame(function() {
            autoLinking = false;
          });
        }
      }

      element.querySelectorAll('a').forEach(function(anchor) {
        anchor.setAttribute('target', '_blank');
        anchor.setAttribute('rel', 'noopener');
      });
    }

    progressInput.addEventListener('input', function() {
      progressValue.textContent = progressInput.value;
      scheduleSave();
    });
    editor.addEventListener('trix-change', function(event) {
      autoLinkUrls(event);
      scheduleSave();
    });

    editor.addEventListener('keydown', function(e) {
      if (e.key === 'Escape') {
        e.preventDefault();
        hideCurrent();
        return;
      }
      if (e.key === 'Enter' && e.altKey) {
        e.preventDefault();
        addChild();
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

    if (parentSuggestBtn && parentSuggestions) {
      parentSuggestBtn.addEventListener('click', function() {
        const originalLabel = parentSuggestBtn.textContent;
        parentSuggestBtn.disabled = true;
        parentSuggestBtn.textContent = `${originalLabel}...`;
        parentSuggestions.innerHTML = '<option>...</option>';
        parentSuggestions.style.display = 'block';

        saveForm()
          .then(function() {
            const id = form.dataset.creativeId;
            if (!id) {
              parentSuggestions.style.display = 'none';
              return;
            }
            return creativesApi.parentSuggestions(id).then(function(data) {
              parentSuggestions.innerHTML = '';
              if (data && data.length) {
                data.forEach(function(s) {
                  const opt = document.createElement('option');
                  opt.value = s.id;
                  opt.textContent = s.path;
                  parentSuggestions.appendChild(opt);
                });
                parentSuggestions.style.display = 'block';
              } else {
                parentSuggestions.style.display = 'none';
              }
            });
          })
          .finally(function() {
            parentSuggestBtn.textContent = originalLabel;
            parentSuggestBtn.disabled = false;
          });
      });
    }

    if (parentSuggestions) {
      parentSuggestions.addEventListener('change', function() {
        if (!this.value) return;
        parentInput.value = this.value;
        const targetId = this.value;
        saveForm().then(function() {
          window.location.href = `/creatives/${targetId}`;
        });
      });
    }

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

    if (addChildBtn) {
      addChildBtn.addEventListener('click', addChild);
    }

    if (deleteBtn) {
      deleteBtn.addEventListener('click', function() {
        if (confirm(deleteBtn.dataset.confirm)) deleteCurrent(false);
      });
    }

      if (deleteWithChildrenBtn) {
        deleteWithChildrenBtn.addEventListener('click', function() {
          if (confirm(deleteWithChildrenBtn.dataset.confirm)) deleteCurrent(true);
        });
      }

      if (linkBtn) {
        linkBtn.addEventListener('click', linkExistingCreative);
      }

      if (linkSearchInput) {
        linkSearchInput.addEventListener('input', searchLinkCreatives);
      }

      if (linkResults) {
        linkResults.addEventListener('click', handleLinkResultClick);
        linkResults.addEventListener('keydown', handleLinkResultKeydown);
      }

      if (linkCloseBtn && linkModal) {
        linkCloseBtn.addEventListener('click', closeLinkModal);
        linkModal.addEventListener('click', function(e) {
          if (e.target === linkModal) closeLinkModal();
        });
      }

      if (unlinkBtn) {
        unlinkBtn.addEventListener('click', function() {
          if (confirm(unlinkBtn.dataset.confirm)) deleteCurrent(false);
        });
      }

      if (unconvertBtn) {
        unconvertBtn.addEventListener('click', function() {
          const creativeId = form.dataset.creativeId;
          if (!creativeId) return;
          const confirmText = unconvertBtn.dataset.confirm;
          if (confirmText && !confirm(confirmText)) return;
          const errorMessage = unconvertBtn.dataset.error || 'Failed to unconvert.';
          unconvertBtn.disabled = true;
          saveForm()
            .then(function(saveResponse) {
              if (saveResponse && saveResponse.ok === false) {
                return saveResponse
                  .json()
                  .catch(function() { return {}; })
                  .then(function(data) {
                    alert(data && data.error ? data.error : errorMessage);
                    const error = new Error('Save failed');
                    error._handled = true;
                    throw error;
                  });
              }
              return creativesApi.unconvert(creativeId);
            })
            .then(function(response) {
              if (response.ok) {
                location.reload();
                return;
              }
              return response
                .json()
                .catch(function() { return {}; })
                .then(function(data) {
                  alert(data && data.error ? data.error : errorMessage);
                });
            })
            .catch(function(error) {
              if (error && error._handled) return;
              alert(errorMessage);
            })
            .finally(function() {
              unconvertBtn.disabled = false;
            });
        });
      }
    });
  }
