import creativesApi from './lib/api/creatives'
import apiQueue from './lib/api/queue_manager'
import { $getCharacterOffsets, $getSelection, $isRangeSelection, $isTextNode, $isRootOrShadowRoot } from 'lexical'
import { createInlineEditor } from './lexical_inline_editor'
import { renderCreativeTree, dispatchCreativeTreeUpdated } from './creatives/tree_renderer'

const BULLET_STARTING_LEVEL = 3;
const HEADING_INDENT_STEP_EM = 0.4;
const BULLET_INDENT_STEP_PX = 30;

let initialized = false;
let creativeEditClickHandler = null;

function deleteAttachment(signedId) {
  if (!signedId) return;
  const csrfToken = document.querySelector('meta[name="csrf-token"]')?.content;
  fetch(`/attachments/${signedId}`, {
    method: 'DELETE',
    headers: {
      'X-CSRF-Token': csrfToken,
    },
  }).catch(err => console.error('Error deleting attachment:', err));
}

export function initializeCreativeRowEditor() {
  if (initialized) return;
  initialized = true;

  document.addEventListener('turbo:load', function () {
    const template = document.getElementById('inline-edit-form');
    if (!template) return;

    initializeEventListeners();

    const form = document.getElementById('inline-edit-form-element');
    const descriptionInput = document.getElementById('inline-creative-description');
    const editorContainer = template.querySelector('[data-lexical-editor-root]');
    const progressInput = document.getElementById('inline-creative-progress');
    const progressValue = document.getElementById('inline-progress-value');
    const upBtn = document.getElementById('inline-move-up');
    const downBtn = document.getElementById('inline-move-down');
    const addBtn = document.getElementById('inline-add');
    const levelDownBtn = document.getElementById('inline-level-down');
    const levelUpBtn = document.getElementById('inline-level-up');
    const deletePopupToggle = document.getElementById('inline-delete-popup-toggle');
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

    let lexicalEditor = null;

    if (!editorContainer) return;

    lexicalEditor = createInlineEditor(editorContainer, {
      onChange: onLexicalChange,
      onKeyDown: handleEditorKeyDown,
      onUploadStateChange: handleUploadStateChange
    });

    let currentTree = null;
    let currentRowElement = null;
    let saveTimer = null;
    let pendingSave = false;
    let saving = false;
    let savePromise = Promise.resolve();
    let uploadsPending = false;
    let uploadCompletionPromise = null;
    let resolveUploadCompletion = null;
    let addNewInProgress = false;
    let originalContent = '';
    let isDirty = false;

    function formatProgressDisplay(value) {
      const numeric = Number(value);
      if (Number.isNaN(numeric)) return '0%';
      const percentage = Math.round(numeric * 100);
      return `${percentage}%`;
    }

    function treeRowElement(node) {
      return node && node.closest ? node.closest('creative-tree-row') : null;
    }

    function hasDatasetValue(element, key) {
      if (!element || !element.dataset) return false;
      return Object.prototype.hasOwnProperty.call(element.dataset, key);
    }

    function setRowDatasetValue(row, key, value) {
      if (!row || !row.dataset) return;
      if (value === undefined || value === null) {
        delete row.dataset[key];
      } else {
        row.dataset[key] = String(value);
      }
    }

    function updateRowFromData(row, data) {
      if (!row || !data) return;
      const descriptionHtml = data.description || '';
      const rawHtml = data.description_raw_html || descriptionHtml;
      row.descriptionHtml = descriptionHtml;
      setRowDatasetValue(row, 'descriptionHtml', descriptionHtml);
      setRowDatasetValue(row, 'descriptionRawHtml', rawHtml);
      if (data.progress_html != null) {
        row.progressHtml = data.progress_html;
        setRowDatasetValue(row, 'progressHtml', data.progress_html);
      }
      if (Object.prototype.hasOwnProperty.call(data, 'progress')) {
        setRowDatasetValue(row, 'progressValue', data.progress ?? '');
      }
      if (Object.prototype.hasOwnProperty.call(data, 'origin_id')) {
        setRowDatasetValue(row, 'originId', data.origin_id ?? '');
      }
      if (Object.prototype.hasOwnProperty.call(data, 'has_children')) {
        if (data.has_children) {
          row.setAttribute('has-children', '');
          row.hasChildren = true;
        } else {
          row.removeAttribute('has-children');
          row.hasChildren = false;
        }
      }
      if (typeof row.requestUpdate === 'function') {
        row.requestUpdate();
      }
    }

    function inlinePayloadFromTree(tree) {
      if (!tree) return null;
      const row = treeRowElement(tree);
      if (!row) return null;

      // Relax validation - allow loading with partial data for instant UI
      const hasDescription = hasDatasetValue(row, 'descriptionRawHtml') || hasDatasetValue(row, 'descriptionHtml');
      const hasProgress = hasDatasetValue(row, 'progressValue');

      // Only require ID to be present
      const id = tree.dataset?.id;
      if (!id) return null;

      const rawHtml = hasDatasetValue(row, 'descriptionRawHtml') ? row.dataset.descriptionRawHtml : row.dataset.descriptionHtml || '';
      const description = row.dataset.descriptionHtml || rawHtml || '';
      const progressValue = hasProgress ? Number(row.dataset.progressValue ?? 0) : 0;
      const parentId = tree.dataset?.parentId || '';

      return {
        id: id,
        description,
        description_raw_html: rawHtml,
        origin_id: row.dataset?.originId || '',
        parent_id: parentId,
        progress: Number.isNaN(progressValue) ? 0 : progressValue
      };
    }

    function isHtmlEmpty(html) {
      if (!html) return true;
      const temp = document.createElement('div');
      temp.innerHTML = html;
      if (temp.querySelector('img')) return false;
      return (temp.textContent || '').trim().length === 0;
    }

    function applyCreativeData(data, tree) {
      if (!data) return;
      const creativeId = data.id;
      if (!creativeId) return;
      form.action = `/creatives/${creativeId}`;
      if (methodInput) methodInput.value = 'patch';
      form.dataset.creativeId = creativeId;
      const content = data.description_raw_html || data.description || '';
      descriptionInput.value = content;
      lexicalEditor.load(content, `creative-${creativeId}-${Date.now()}`);
      pendingSave = false;
      // Track original content for dirty state detection
      originalContent = content;
      isDirty = false;
      const progressNumber = Number(data.progress ?? 0);
      const normalizedProgress = Number.isNaN(progressNumber) ? 0 : progressNumber;
      progressInput.value = normalizedProgress;
      progressValue.textContent = formatProgressDisplay(progressInput.value);
      const fallbackParent = tree?.dataset?.parentId || '';
      parentInput.value = data.parent_id ?? fallbackParent ?? '';
      beforeInput.value = '';
      afterInput.value = '';
      if (childInput) childInput.value = '';
      const originId = data.origin_id || '';
      if (linkBtn) linkBtn.style.display = originId ? 'none' : '';
      if (unlinkBtn) unlinkBtn.style.display = originId ? '' : 'none';
      const effectiveParent = parentInput.value;
      if (unconvertBtn) unconvertBtn.style.display = effectiveParent ? '' : 'none';
      lexicalEditor.focus();
      updateActionButtonStates();
    }

    function siblingTreeRow(row, direction) {
      if (!row) return null;
      const step = direction === 'previous' ? 'previousSibling' : 'nextSibling';
      let node = row[step];
      while (node) {
        if (node.nodeType === Node.TEXT_NODE) {
          node = node[step];
          continue;
        }
        if (node.matches?.('creative-tree-row')) return node;
        if (node.classList?.contains?.('creative-children')) {
          node = node[step];
          continue;
        }
        node = node[step];
      }
      return null;
    }

    function siblingOrderingForRow(row) {
      const beforeRow = siblingTreeRow(row, 'next');
      const afterRow = siblingTreeRow(row, 'previous');
      return {
        beforeId: beforeRow ? creativeIdFrom(beforeRow) : '',
        afterId: afterRow ? creativeIdFrom(afterRow) : ''
      };
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

    function childrenContainerForTree(tree) {
      if (!tree) return null;
      const treeId = tree.dataset?.id;
      if (treeId) {
        const byId = document.getElementById(`creative-children-${treeId}`);
        if (byId) return byId;
      }
      if (tree.children && tree.children.length > 0) {
        for (const child of tree.children) {
          if (child && child.classList && child.classList.contains('creative-children')) {
            return child;
          }
        }
      }
      const row = treeRowElement(tree);
      if (row) {
        let sibling = row.nextElementSibling;
        while (sibling) {
          if (sibling.matches?.('creative-tree-row')) break;
          if (sibling.classList?.contains('creative-children')) return sibling;
          sibling = sibling.nextElementSibling;
        }
      }
      return null;
    }

    function buildChildrenLoadUrl(parentId, childLevel, selectMode) {
      const params = new URLSearchParams();
      params.set('level', String(childLevel));
      params.set('select_mode', selectMode ? '1' : '0');
      return `/creatives/${parentId}/children?${params.toString()}`;
    }

    function ensureChildrenContainer(tree) {
      if (!tree) return null;
      let container = childrenContainerForTree(tree);
      if (container) return container;
      const parentId = tree.dataset?.id;
      if (!parentId) return null;
      container = document.createElement('div');
      container.className = 'creative-children';
      container.id = `creative-children-${parentId}`;
      const parentRow = treeRowElement(tree);
      const parentLevel = readRowLevel(parentRow) || 1;
      const childLevel = parentLevel + 1;
      const selectModeActive = parentRow?.hasAttribute?.('select-mode') ? 1 : 0;
      container.dataset.loadUrl = buildChildrenLoadUrl(parentId, childLevel, selectModeActive);
      container.dataset.expanded = 'true';
      if (container.dataset.loaded) delete container.dataset.loaded;
      const row = treeRowElement(tree);
      const parentContainer = row?.parentNode || tree.parentNode;
      if (parentContainer) {
        const afterRow = row?.nextSibling;
        if (afterRow) {
          parentContainer.insertBefore(container, afterRow);
        } else {
          parentContainer.appendChild(container);
        }
      } else {
        tree.appendChild(container);
      }
      return container;
    }

    function expandChildrenContainer(container) {
      if (!container) return;
      container.style.display = '';
      if (container.dataset) {
        container.dataset.expanded = 'true';
      }
    }

    function moveTreeBlock(tree, targetContainer, referenceNode = null) {
      if (!tree || !targetContainer) return;
      const row = treeRowElement(tree);
      if (!row) return;
      const nodesToMove = [row];
      const childContainer = childrenContainerForTree(tree);
      if (childContainer) nodesToMove.push(childContainer);
      nodesToMove.forEach((node) => {
        if (!node) return;
        if (referenceNode) {
          targetContainer.insertBefore(node, referenceNode);
        } else {
          targetContainer.appendChild(node);
        }
      });
    }

    function listAllTreeNodes() {
      const root = document.getElementById('creatives');
      if (root) return Array.from(root.querySelectorAll('.creative-tree'));
      return Array.from(document.querySelectorAll('.creative-tree'));
    }

    function findPreviousTree(tree) {
      if (!tree) return null;
      const nodes = listAllTreeNodes();
      const index = nodes.indexOf(tree);
      if (index <= 0) return null;
      const currentLevel = getTreeLevel(tree);
      for (let i = index - 1; i >= 0; i--) {
        const candidate = nodes[i];
        if (!candidate) continue;
        const candidateLevel = getTreeLevel(candidate);
        if (candidateLevel === currentLevel) return candidate;
        if (candidateLevel < currentLevel) return null;
      }
      return null;
    }

    function getTreeLevel(tree) {
      if (!tree) return 1;
      const levelValue = Number(tree.dataset?.level);
      if (!Number.isNaN(levelValue) && levelValue > 0) {
        return levelValue;
      }
      const row = treeRowElement(tree);
      return readRowLevel(row) || 1;
    }

    function updateTreeLevels(tree, delta) {
      if (!tree || !delta) return;
      const currentLevel = Number(tree.dataset?.level) || 1;
      const nextLevel = Math.max(1, currentLevel + delta);
      tree.dataset.level = String(nextLevel);
      const row = treeRowElement(tree);
      if (row) {
        row.setAttribute('level', nextLevel);
        row.level = nextLevel;
        row.requestUpdate?.();
      }
      const container = childrenContainerForTree(tree);
      if (!container) return;
      Array.from(container.children || []).forEach((childRow) => {
        if (!childRow.matches?.('creative-tree-row')) return;
        const childTree = childRow.querySelector('.creative-tree');
        if (childTree) {
          updateTreeLevels(childTree, delta);
        }
      });
    }

    function setTreeLevel(tree, targetLevel) {
      if (!tree || typeof targetLevel !== 'number') return;
      const currentLevel = Number(tree.dataset?.level) || 1;
      const delta = targetLevel - currentLevel;
      if (delta === 0) return;
      updateTreeLevels(tree, delta);
    }

    function updateParentChildrenState(parentId) {
      if (!parentId) return;
      const parentTree = document.getElementById(`creative-${parentId}`);
      if (!parentTree) return;
      const parentRow = treeRowElement(parentTree);
      if (!parentRow) return;
      const container = childrenContainerForTree(parentTree);
      const hasChildren = Boolean(container && container.querySelector('creative-tree-row'));
      if (hasChildren) {
        parentRow.setAttribute('has-children', '');
        parentRow.hasChildren = true;
        expandChildrenContainer(container);
      } else {
        parentRow.removeAttribute('has-children');
        parentRow.hasChildren = false;
        if (container) container.style.display = 'none';
      }
      parentRow.requestUpdate?.();
    }

    function persistStructureChange(newParentId, { beforeId = '', afterId = '' } = {}) {
      parentInput.value = newParentId || '';
      beforeInput.value = beforeId || '';
      afterInput.value = afterId || '';
      if (childInput) childInput.value = '';
      pendingSave = true;
      scheduleSave();
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

    function editorPaddingForLevel(level) {
      if (typeof level !== 'number' || Number.isNaN(level) || level <= 1) {
        return '0px';
      }
      if (level <= BULLET_STARTING_LEVEL) {
        const emValue = (level - 1) * HEADING_INDENT_STEP_EM;
        return emValue ? `${emValue}em` : '0px';
      }
      const pxValue = (level - BULLET_STARTING_LEVEL) * BULLET_INDENT_STEP_PX;
      return `${pxValue}px`;
    }

    function syncInlineEditorPadding(source) {
      if (!template) return;
      let level = null;
      if (typeof source === 'number') {
        level = source;
      } else if (source) {
        level = readRowLevel(source);
      }
      const paddingValue = editorPaddingForLevel(level);
      template.style.paddingLeft = paddingValue;
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

    function getUploadCompletion() {
      if (!uploadCompletionPromise) {
        uploadCompletionPromise = new Promise(resolve => {
          resolveUploadCompletion = resolve;
        });
      }
      return uploadCompletionPromise;
    }

    function updateActionButtonStates() {
      const hasCurrent = Boolean(currentTree);
      const trees = hasCurrent ? listAllTreeNodes() : [];
      const index = hasCurrent ? trees.indexOf(currentTree) : -1;
      const hasCreativeId = Boolean(form.dataset?.creativeId);

      if (upBtn) upBtn.disabled = !(hasCurrent && index > 0);
      if (downBtn) downBtn.disabled = !(hasCurrent && index >= 0 && index < trees.length - 1);

      let canLevelDown = false;
      if (hasCurrent) {
        const previousTree = findPreviousTree(currentTree);
        const previousId = previousTree?.dataset?.id;
        canLevelDown = Boolean(previousTree && previousId && previousId !== currentTree.dataset?.parentId);
      }
      if (levelDownBtn) levelDownBtn.disabled = !canLevelDown;

      let canLevelUp = false;
      if (hasCurrent) {
        const parentId = currentTree.dataset?.parentId;
        const parentTree = parentId ? document.getElementById(`creative-${parentId}`) : null;
        const targetContainer = parentTree ? treeContainerElement(parentTree) : null;
        canLevelUp = Boolean(parentId && parentTree && targetContainer);
      }
      if (levelUpBtn) levelUpBtn.disabled = !canLevelUp;

      if (deletePopupToggle) deletePopupToggle.disabled = !hasCreativeId;
      if (deleteBtn) deleteBtn.disabled = !hasCreativeId;
      if (deleteWithChildrenBtn) deleteWithChildrenBtn.disabled = !hasCreativeId;
      if (linkBtn) linkBtn.disabled = !hasCreativeId || linkBtn.style.display === 'none';
      if (unlinkBtn) unlinkBtn.disabled = !hasCreativeId || unlinkBtn.style.display === 'none';
      if (unconvertBtn) {
        const unconvertVisible = unconvertBtn.style.display !== 'none';
        const hasParent = Boolean(parentInput.value);
        unconvertBtn.disabled = !(hasCreativeId && hasParent && unconvertVisible);
      }

      if (addBtn) addBtn.disabled = !hasCurrent;
      if (closeBtn) closeBtn.disabled = uploadsPending || !hasCurrent;
    }

    function waitForUploads() {
      return uploadsPending ? getUploadCompletion() : Promise.resolve();
    }

    function handleUploadStateChange(pending) {
      uploadsPending = Boolean(pending);
      if (closeBtn) closeBtn.disabled = uploadsPending;
      if (template) {
        if (uploadsPending) {
          template.dataset.uploading = 'true';
        } else {
          delete template.dataset.uploading;
        }
      }
      if (uploadsPending) {
        getUploadCompletion();
      } else if (resolveUploadCompletion) {
        resolveUploadCompletion();
        uploadCompletionPromise = null;
        resolveUploadCompletion = null;
      }
      updateActionButtonStates();
    }

    function attachTemplate(tree) {
      if (!tree) return;
      const childrenContainer = tree.querySelector('.creative-children');
      if (childrenContainer && childrenContainer.parentNode === tree) {
        tree.insertBefore(template, childrenContainer);
      } else {
        tree.appendChild(template);
      }
    }

    async function handleEditButtonClick(tree) {
      if (!tree) return;

      if (currentTree === tree) {
        await hideCurrent();
        return;
      }
      if (currentTree) {
        await hideCurrent(false);
      }
      currentTree = tree;
      currentRowElement = treeRowElement(tree);
      syncInlineEditorPadding(currentRowElement);
      hideRow(tree);
      tree.draggable = false;
      attachTemplate(tree);
      template.style.display = 'block';
      loadCreative(tree);
      updateActionButtonStates();
    }

    function initializeEventListeners() {
      if (!creativeEditClickHandler) {
        creativeEditClickHandler = function (e) {
          const tree = e.detail?.treeElement || e.detail?.button?.closest('.creative-tree');
          if (!tree) return;
          e.preventDefault();
          handleEditButtonClick(tree);
        };
        document.addEventListener('creative-edit-click', creativeEditClickHandler);
      }

      document.body.addEventListener('click', function (e) {
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
        const addBtn = e.target.closest('.add-creative-btn:not(#inline-add):not(#inline-level-down):not(#inline-level-up)');
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
      if (!tree) return;
      const id = tree.dataset?.id;
      if (!id) return;
      const rowEl = treeRowElement(tree);
      creativesApi.get(id)
        .then(data => {
          updateRowFromData(rowEl, data);
        });
    }

    function refreshChildren(tree) {
      const container = tree.querySelector('.creative-children');
      if (!container) { return Promise.resolve(); }
      const url = container.dataset.loadUrl;
      if (!url) { return Promise.resolve(); }
      return creativesApi.loadChildren(url)
        .then(data => {
          const nodes = Array.isArray(data?.creatives) ? data.creatives : [];
          renderCreativeTree(container, nodes, { replace: false });
          container.dataset.loaded = 'true';
          dispatchCreativeTreeUpdated(container);
        });
    }

    function saveForm(tree = currentTree, parentId = parentInput.value) {
      return waitForUploads().then(function () {
        if (saving) return savePromise;
        clearTimeout(saveTimer);

        if (isHtmlEmpty(descriptionInput.value)) {
          pendingSave = false;
          return Promise.resolve();
        }

        const method = methodInput.value === 'patch' ? 'PATCH' : 'POST';
        pendingSave = false;
        if (!form.action) return Promise.resolve();
        saving = true;
        savePromise = creativesApi.save(form.action, method, form).then(function (r) {
          if (!r.ok) return r;
          return r.text().then(function (text) {
            try { return text ? JSON.parse(text) : {}; } catch (e) { return {}; }
          }).then(function (data) {
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

            // Delete removed attachments after successful save
            if (lexicalEditor && typeof lexicalEditor.getDeletedAttachments === 'function') {
              const deletedIds = lexicalEditor.getDeletedAttachments();
              if (deletedIds && deletedIds.length > 0) {
                deletedIds.forEach(deleteAttachment);
              }
            }
            updateActionButtonStates();
          });
        }).finally(function () {
          saving = false;
        });
        return savePromise;
      });
    }

    function hideCurrent(event) {
      if (event?.preventDefault) {
        event.preventDefault();
      }
      if (!currentTree) return Promise.resolve();
      const tree = currentTree;
      const parentId = parentInput.value;
      const wasNew = !form.dataset.creativeId;
      currentTree = null;
      currentRowElement = null;
      tree.draggable = true;
      updateActionButtonStates();

      const finalizeHide = function () {
        template.style.display = 'none';
        const p = (pendingSave || saving) ? saveForm(tree, parentId) : Promise.resolve();
        return p.then(() => {
          if (wasNew && !form.dataset.creativeId) {
            removeTreeElement(tree);
          } else if (!tree.querySelector('.creative-row')) {
            const parentTree = parentId ? document.getElementById(`creative-${parentId}`) : null;
            if (parentTree) {
              refreshChildren(parentTree);
            }
          } else {
            showRow(tree);
            refreshRow(tree);
          }
        });
      };

      if (uploadsPending) {
        return waitForUploads().then(finalizeHide);
      }

      return finalizeHide();
    }

    function loadCreative(tree) {
      if (!tree) return;
      const id = tree.dataset?.id;
      if (!id) return;

      // Always try to use cached data from the row first for instant loading
      const inlineData = inlinePayloadFromTree(tree);
      if (inlineData && inlineData.id) {
        console.log('✅ Using cached data for creative', id, '- NO API CALL');
        applyCreativeData(inlineData, tree);
        return;
      }

      // Fallback: if no cached data, fetch from API
      // This should rarely happen as rows are pre-rendered with data
      console.warn('⚠️ No cached data for creative', id, '- making API call');
      creativesApi.get(id)
        .then(data => {
          updateRowFromData(treeRowElement(tree), data);
          applyCreativeData(data, tree);
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

    /**
     * Queue save if content has been modified
     * This allows UI operations to proceed without waiting for API response
     */
    function queueSaveIfDirty() {
      // Check both isDirty (text changes) and pendingSave (progress/structure changes)
      if (!isDirty && !pendingSave) return;

      const creativeId = form.dataset?.creativeId;
      if (!creativeId) return;

      const currentContent = descriptionInput.value;
      const currentProgress = Number(progressInput.value ?? 0);
      const currentParentId = parentInput.value || '';
      const currentBeforeId = beforeInput.value || '';
      const currentAfterId = afterInput.value || '';

      // Build request body
      const body = {
        'creative[description]': currentContent,
        'creative[progress]': currentProgress
      };

      if (currentParentId) {
        body['creative[parent_id]'] = currentParentId;
      }
      if (currentBeforeId) {
        body['creative[before_id]'] = currentBeforeId;
      }
      if (currentAfterId) {
        body['creative[after_id]'] = currentAfterId;
      }

      // Update row dataset immediately to keep cached data fresh
      // This prevents stale data when returning to this creative later
      if (currentTree) {
        const row = treeRowElement(currentTree);
        if (row) {
          row.dataset.descriptionHtml = currentContent;
          row.dataset.descriptionRawHtml = currentContent;
          row.dataset.progressValue = String(currentProgress);
          if (currentParentId) {
            currentTree.dataset.parentId = currentParentId;
          }
        }
      }

      // Delete removed attachments immediately to prevent orphaned files
      // This must happen before queueing to ensure cleanup even if navigation is immediate
      if (lexicalEditor && typeof lexicalEditor.getDeletedAttachments === 'function') {
        const deletedIds = lexicalEditor.getDeletedAttachments();
        if (deletedIds && deletedIds.length > 0) {
          deletedIds.forEach(deleteAttachment);
        }
      }

      // Queue the save request
      apiQueue.enqueue({
        path: `/creatives/${creativeId}`,
        method: 'PATCH',
        body: body,
        dedupeKey: `creative_${creativeId}`
      });

      // Reset dirty state
      originalContent = currentContent;
      isDirty = false;
      pendingSave = false;
      clearTimeout(saveTimer);
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

      // Queue save if dirty (non-blocking)
      if (!wasNew) {
        queueSaveIfDirty();
      }

      // Update UI immediately
      currentTree = target;
      currentRowElement = treeRowElement(target);
      syncInlineEditorPadding(currentRowElement);
      hideRow(target);
      attachTemplate(target);
      template.style.display = 'block';

      // Handle new creative cleanup or show previous row
      if (wasNew) {
        // For new creatives, still need to save or cleanup
        beforeNewOrMove(wasNew, prev, prevParent).then(() => {
          loadCreative(target);
        });
      } else {
        // For existing creatives, show the row and refresh if needed
        if (prev.querySelector('.creative-row')) {
          showRow(prev);
        }
        loadCreative(target);
      }

      updateActionButtonStates();
    }

    function addNew() {
      if (!currentTree) return;

      // Prevent multiple simultaneous calls to addNew (e.g., from Lexical onChange + keyboard event)
      if (addNewInProgress) {
        return;
      }
      addNewInProgress = true;
      setTimeout(() => { addNewInProgress = false; }, 300);

      const prev = currentTree;
      const wasNew = !form.dataset.creativeId;
      const prevParent = parentInput.value;

      // Queue save if dirty (non-blocking)
      if (!wasNew) {
        queueSaveIfDirty();
      }

      const handleAddNew = () => {
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
      };

      if (wasNew) {
        // For new creatives, still need to save or cleanup
        beforeNewOrMove(wasNew, prev, prevParent).then(handleAddNew).finally(() => {
          addNewInProgress = false;
        });
      } else {
        // For existing creatives, show the row if it exists and proceed
        if (prev.querySelector('.creative-row')) {
          showRow(prev);
        }
        handleAddNew();
        addNewInProgress = false;
      }
    }

    function addChild() {
      if (!currentTree) return;
      const prev = currentTree;
      const wasNew = !form.dataset.creativeId;
      const prevParent = parentInput.value;

      // Queue save if dirty (non-blocking)
      if (!wasNew) {
        queueSaveIfDirty();
      }

      const handleAddChild = () => {
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
      };

      if (wasNew) {
        // For new creatives, still need to save or cleanup
        beforeNewOrMove(wasNew, prev, prevParent).then(handleAddChild);
      } else {
        // For existing creatives, show the row if it exists and proceed
        if (prev.querySelector('.creative-row')) {
          showRow(prev);
        }
        handleAddChild();
      }
    }

    function levelDown() {
      if (!currentTree) return;
      const previousTree = findPreviousTree(currentTree);
      if (!previousTree) return;
      const previousId = previousTree.dataset?.id;
      if (!previousId || previousId === currentTree.dataset?.id) return;
      if (currentTree.dataset?.parentId === previousId) return;
      const targetContainer = ensureChildrenContainer(previousTree);
      if (!targetContainer) return;
      expandChildrenContainer(targetContainer);
      const oldParentId = currentTree.dataset?.parentId || '';
      moveTreeBlock(currentTree, targetContainer);
      currentTree.dataset.parentId = previousId;
      if (currentRowElement) {
        currentRowElement.setAttribute('parent-id', previousId);
        currentRowElement.parentId = previousId;
        currentRowElement.removeAttribute('is-root');
        currentRowElement.isRoot = false;
        currentRowElement.requestUpdate?.();
      }
      updateParentChildrenState(previousId);
      if (oldParentId) updateParentChildrenState(oldParentId);
      const newLevel = getTreeLevel(previousTree) + 1;
      setTreeLevel(currentTree, newLevel);
      syncInlineEditorPadding(newLevel);
      const row = treeRowElement(currentTree);
      const ordering = siblingOrderingForRow(row);
      persistStructureChange(previousId, ordering);
      lexicalEditor.focus();
      updateActionButtonStates();
    }

    function levelUp() {
      if (!currentTree) return;
      const parentId = currentTree.dataset?.parentId;
      if (!parentId) return;
      const parentTree = document.getElementById(`creative-${parentId}`);
      if (!parentTree) return;
      const targetContainer = treeContainerElement(parentTree);
      if (!targetContainer) return;
      const insertionPoint = nodeAfterTreeBlock(parentTree);
      moveTreeBlock(currentTree, targetContainer, insertionPoint || null);
      const grandParentId = parentTree.dataset?.parentId || '';
      if (grandParentId) {
        currentTree.dataset.parentId = grandParentId;
      } else {
        delete currentTree.dataset.parentId;
      }
      if (currentRowElement) {
        if (grandParentId) {
          currentRowElement.setAttribute('parent-id', grandParentId);
          currentRowElement.parentId = grandParentId;
          currentRowElement.removeAttribute('is-root');
          currentRowElement.isRoot = false;
        } else {
          currentRowElement.removeAttribute('parent-id');
          currentRowElement.parentId = null;
          currentRowElement.setAttribute('is-root', '');
          currentRowElement.isRoot = true;
        }
        currentRowElement.requestUpdate?.();
      }
      updateParentChildrenState(parentId);
      updateParentChildrenState(grandParentId);
      if (targetContainer.classList?.contains('creative-children')) {
        expandChildrenContainer(targetContainer);
      }
      const grandParentTree = grandParentId ? document.getElementById(`creative-${grandParentId}`) : null;
      const newLevel = grandParentTree ? getTreeLevel(grandParentTree) + 1 : 1;
      setTreeLevel(currentTree, newLevel);
      syncInlineEditorPadding(newLevel);
      const row = treeRowElement(currentTree);
      const ordering = siblingOrderingForRow(row);
      persistStructureChange(grandParentId, ordering);
      lexicalEditor.focus();
      updateActionButtonStates();
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
      creativesApi
        .search(query, { simple: true })
        .then(results => {
          linkResults.innerHTML = '';
          if (Array.isArray(results)) {
            results.forEach(function (c) {
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
      creativesApi.linkExisting(form.dataset.creativeId, li.dataset.id).then(() => {
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
      const performStart = () => {
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
          syncInlineEditorPadding(level);
          attachTemplate(newTree);
          template.style.display = 'block';
          form.action = '/creatives';
          methodInput.value = '';
          form.dataset.creativeId = '';
          parentInput.value = parentId || '';
          beforeInput.value = beforeId || '';
          afterInput.value = afterId || '';
          if (childInput) childInput.value = childId || '';
          descriptionInput.value = '';
          lexicalEditor.reset(`new-${Date.now()}`);
          progressInput.value = 0;
          progressValue.textContent = formatProgressDisplay(0);
          if (linkBtn) linkBtn.style.display = '';
          if (unlinkBtn) unlinkBtn.style.display = 'none';
          if (unconvertBtn) unconvertBtn.style.display = 'none';
          pendingSave = false;
          lexicalEditor.focus();
          updateActionButtonStates();
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
      };

      if (currentTree) {
        return Promise.resolve(hideCurrent(false)).then(performStart);
      }

      return performStart();
    }

    function scheduleSave() {
      pendingSave = true;
      clearTimeout(saveTimer);
      saveTimer = setTimeout(saveForm, 5000);
    }

    function onLexicalChange(html) {
      descriptionInput.value = html;
      // Mark as dirty if content changed from original
      isDirty = (html !== originalContent);
      scheduleSave();
    }

    function handleEditorKeyDown(event, editorInstance) {
      if (!editorInstance) return;
      if (event.key === 'Escape') {
        event.preventDefault();
        hideCurrent();
        return;
      }
      if (event.key === 'Enter' && event.altKey) {
        event.preventDefault();
        addChild();
        return;
      }
      if (event.key === 'Enter' && event.shiftKey) {
        event.preventDefault();
        addNew();
        return;
      }
      if ((event.ctrlKey || event.metaKey) && event.shiftKey && (event.key === '.' || event.key === '>')) {
        event.preventDefault();
        levelDown();
        return;
      }
      if ((event.ctrlKey || event.metaKey) && event.shiftKey && (event.key === ',' || event.key === '<')) {
        event.preventDefault();
        levelUp();
        return;
      }
      const normalizedKey = typeof event.key === 'string' ? event.key.toLowerCase() : '';
      const isArrowUp = event.key === 'ArrowUp';
      const isArrowDown = event.key === 'ArrowDown';
      const isCtrlP = normalizedKey === 'p' && (event.ctrlKey || event.metaKey);
      const isCtrlN = normalizedKey === 'n' && (event.ctrlKey || event.metaKey);

      if (!(isArrowUp || isArrowDown || isCtrlP || isCtrlN)) return;

      let atStart = false;
      let atEnd = false;
      editorInstance.getEditorState().read(() => {
        const selection = $getSelection();
        if (!$isRangeSelection(selection) || !selection.isCollapsed()) return;
        const [start, end] = $getCharacterOffsets(selection);
        atStart = start === 0 && end === 0;
        atEnd = isSelectionAtDocumentEnd(selection);
      });

      if ((isArrowUp || isCtrlP) && atStart) {
        event.preventDefault();
        if (pendingSave) saveForm();
        move(-1);
        requestAnimationFrame(() => lexicalEditor.focus());
        return;
      }

      if ((isArrowDown || isCtrlN) && atEnd) {
        event.preventDefault();
        if (pendingSave) saveForm();
        move(1);
        requestAnimationFrame(() => lexicalEditor.focus());
      }
    }

    function isSelectionAtDocumentEnd(selection) {
      if (!$isRangeSelection(selection) || !selection.isCollapsed()) return false;

      const focus = selection.focus;
      let node = focus.getNode();
      if (!node) return false;

      const offset = focus.offset;
      if ($isTextNode(node)) {
        if (offset !== node.getTextContentSize()) return false;
      } else if (typeof node.getChildrenSize === 'function') {
        if (offset !== node.getChildrenSize()) return false;
      } else {
        // Fallback for nodes without children size (e.g., line breaks)
        const textSize = node.getTextContentSize?.() ?? 0;
        if (offset !== textSize) return false;
      }

      while (node && !$isRootOrShadowRoot(node)) {
        if (node.getNextSibling()) return false;
        node = node.getParent();
      }

      return !!node && $isRootOrShadowRoot(node);
    }

    progressInput.addEventListener('input', function () {
      progressValue.textContent = formatProgressDisplay(progressInput.value);
      scheduleSave();
    });

    if (parentSuggestBtn && parentSuggestions) {
      parentSuggestBtn.addEventListener('click', function () {
        const originalLabel = parentSuggestBtn.textContent;
        parentSuggestBtn.disabled = true;
        parentSuggestBtn.textContent = `${originalLabel}...`;
        parentSuggestions.innerHTML = '<option>...</option>';
        parentSuggestions.style.display = 'block';

        saveForm()
          .then(function () {
            const id = form.dataset.creativeId;
            if (!id) {
              parentSuggestions.style.display = 'none';
              return;
            }
            return creativesApi.parentSuggestions(id).then(function (data) {
              parentSuggestions.innerHTML = '';
              if (data && data.length) {
                data.forEach(function (s) {
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
          .finally(function () {
            parentSuggestBtn.textContent = originalLabel;
            parentSuggestBtn.disabled = false;
          });
      });
    }

    if (parentSuggestions) {
      parentSuggestions.addEventListener('change', function () {
        if (!this.value) return;
        parentInput.value = this.value;
        const targetId = this.value;
        saveForm().then(function () {
          window.location.href = `/creatives/${targetId}`;
        });
      });
    }

    if (closeBtn) {
      closeBtn.addEventListener('click', hideCurrent);
    }

    upBtn.addEventListener('click', function () {
      if (pendingSave) saveForm();
      move(-1);
    });
    downBtn.addEventListener('click', function () {
      if (pendingSave) saveForm();
      move(1);
    });

    if (addBtn) {
      addBtn.addEventListener('click', addNew);
    }

    if (levelDownBtn) {
      levelDownBtn.addEventListener('click', levelDown);
    }

    if (levelUpBtn) {
      levelUpBtn.addEventListener('click', levelUp);
    }

    if (deleteBtn) {
      deleteBtn.addEventListener('click', function () {
        if (confirm(deleteBtn.dataset.confirm)) deleteCurrent(false);
      });
    }

    if (deleteWithChildrenBtn) {
      deleteWithChildrenBtn.addEventListener('click', function () {
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
      linkModal.addEventListener('click', function (e) {
        if (e.target === linkModal) closeLinkModal();
      });
    }

    if (unlinkBtn) {
      unlinkBtn.addEventListener('click', function () {
        if (confirm(unlinkBtn.dataset.confirm)) deleteCurrent(false);
      });
    }

    if (unconvertBtn) {
      unconvertBtn.addEventListener('click', function () {
        const creativeId = form.dataset.creativeId;
        if (!creativeId) return;
        const confirmText = unconvertBtn.dataset.confirm;
        if (confirmText && !confirm(confirmText)) return;
        const errorMessage = unconvertBtn.dataset.error || 'Failed to unconvert.';
        unconvertBtn.disabled = true;
        saveForm()
          .then(function (saveResponse) {
            if (saveResponse && saveResponse.ok === false) {
              return saveResponse
                .json()
                .catch(function () { return {}; })
                .then(function (data) {
                  alert(data && data.error ? data.error : errorMessage);
                  const error = new Error('Save failed');
                  error._handled = true;
                  throw error;
                });
            }
            return creativesApi.unconvert(creativeId);
          })
          .then(function (response) {
            if (response.ok) {
              location.reload();
              return;
            }
            return response
              .json()
              .catch(function () { return {}; })
              .then(function (data) {
                alert(data && data.error ? data.error : errorMessage);
              });
          })
          .catch(function (error) {
            if (error && error._handled) return;
            alert(errorMessage);
          })
          .finally(function () {
            unconvertBtn.disabled = false;
          });
      });
    }
  });
}
