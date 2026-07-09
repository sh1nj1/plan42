import creativesApi from '../lib/api/creatives'
import apiQueue from '../lib/api/queue_manager'
import { $getSelection } from 'lexical'
import { isSelectionAtDocumentStart, isSelectionAtDocumentEnd } from '../lib/lexical/selection_boundary'
import { createInlineEditor } from './lexical_inline_editor'
import { renderCreativeTree, dispatchCreativeTreeUpdated } from '../creatives/tree_renderer'
import { isProgressComplete, progressBaselineValueFrom, progressValueChangedFrom } from './creative_progress'
import { renderMarkdown } from '../lib/utils/markdown'
import { reconcileMarkdownSource } from './markdown_source_reconcile'
import { isHtmlEmpty } from './html_content_empty'
import { confirmDialog, alertDialog } from '../lib/utils/dialog'
import { serverErrorMessage } from '../lib/api/api_error'
import yaml from 'js-yaml'
// Import Stimulus application from the global window (set by host app)
const application = window.Stimulus

const BULLET_STARTING_LEVEL = 3;
const HEADING_INDENT_STEP_EM = 0.4;
const BULLET_INDENT_STEP_PX = 30;

let initialized = false;
let creativeEditClickHandler = null;
let addCreativeShortcutHandler = null;

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

    // Listen for attachment deletions from queue manager
    window.addEventListener('api-queue-attachments-deleted', (event) => {
      const attachmentIds = event.detail?.attachmentIds;
      if (attachmentIds && attachmentIds.length > 0) {
        attachmentIds.forEach(deleteAttachment);
      }
    });

    // Listen for failed requests to prevent silent data loss
    window.addEventListener('api-queue-request-failed', (event) => {
      const { item, error } = event.detail;
      console.error('Queue request failed permanently:', item, error);

      // Alert the user
      // In a real app, use a toast notification. For now, alert is safe.
      // Suppress 404 errors for PATCH requests, as this likely means the item was deleted
      // and we don't need to alert the user about it.
      const is404 = (error && error.status === 404) || (error && error.toString().includes('404'));
      const isPatch = item && item.method === 'PATCH';

      if (!(is404 && isPatch)) {
        // Prefer the server's own error message (e.g. "Description cannot be
        // changed directly for GitHub synced content") and fall back to the
        // generic copy only when the failure carries no usable payload.
        const serverMessage = serverErrorMessage(error);
        alertDialog(serverMessage || 'Failed to save changes. Please check your connection and try again.');
      }

      // If the failed item matches the current creative, mark it as dirty so it can be retried
      if (form.dataset.creativeId && item.path.includes(form.dataset.creativeId)) {
        console.log('Restoring dirty state for current creative');
        isDirty = true;
        pendingSave = true;
        setSaveStatus('error');
        updateActionButtonStates();
      }
    });

    // ... rest of initialization

    // Reflect the inline editor's save lifecycle in the toolbar row.
    // Plain JS controller can't call the i18n `t()` helper, so the localized
    // strings are carried on the span's data-* attributes (set in the ERB).
    // state: 'pending' | 'saving' | 'saved' | 'error' | '' (cleared).
    // 'pending' = dirty, waiting out the debounce; 'saving' = request in flight.
    function setSaveStatus(state) {
      const el = document.getElementById('inline-save-status');
      if (!el) return;
      const label = state ? el.dataset[`label${state.charAt(0).toUpperCase()}${state.slice(1)}`] : '';
      el.textContent = label || '';
      el.dataset.state = state || '';
    }

    const form = document.getElementById('inline-edit-form-element');
    const descriptionInput = document.getElementById('inline-creative-description');
    const editorContainer = template.querySelector('[data-lexical-editor-root]');
    const progressInput = document.getElementById('inline-creative-progress');
    const progressValue = document.getElementById('inline-progress-value');
    const progressCompleteLabel = progressInput?.dataset.completeLabel || 'Complete';
    const progressIncompleteLabel = progressInput?.dataset.incompleteLabel || 'Incomplete';
    const progressHiddenInput = document.querySelector('input[type="hidden"][name="creative[progress]"]');
    const upBtn = document.getElementById('inline-move-up');
    const downBtn = document.getElementById('inline-move-down');
    const addBtn = document.getElementById('inline-add');
    const levelDownBtn = document.getElementById('inline-level-down');
    const levelUpBtn = document.getElementById('inline-level-up');
    const deletePopupToggle = document.getElementById('inline-delete-popup-toggle');
    const archiveBtn = document.getElementById('inline-archive');
    const deleteBtn = document.getElementById('inline-delete');
    const deleteWithChildrenBtn = document.getElementById('inline-delete-with-children');
    const linkBtn = document.getElementById('inline-link');
    const unlinkBtn = document.getElementById('inline-unlink');
    const unconvertBtn = document.getElementById('inline-unconvert');
    const closeBtn = document.getElementById('inline-close');
    const parentSuggestions = document.getElementById('parent-suggestions');
    const parentSuggestBtn = document.getElementById('inline-recommend-parent');
    const methodInput = document.getElementById('inline-method');
    const parentInput = document.getElementById('inline-parent-id');
    const beforeInput = document.getElementById('inline-before-id');
    const afterInput = document.getElementById('inline-after-id');
    const childInput = document.getElementById('inline-child-id');
    const originIdInput = document.getElementById('inline-origin-id');
    const metadataBtn = document.getElementById('inline-metadata-btn');
    const metadataPopup = document.getElementById('metadata-popup');
    const metadataEditor = document.getElementById('metadata-yaml-editor');
    const metadataSaveBtn = document.getElementById('metadata-save-btn');
    const metadataCloseBtn = document.getElementById('metadata-popup-close');

    // Markdown editor elements
    const contentTypeInput = document.getElementById('inline-content-type');
    const markdownEditorInput = document.getElementById('inline-markdown-editor');
    const markdownSourceInput = document.getElementById('inline-markdown-source');
    const markdownWrapper = document.getElementById('markdown-editor-wrapper');
    const markdownTextarea = document.getElementById('markdown-editor-textarea');
    const markdownPreview = document.getElementById('markdown-preview');
    const toggleMarkdownBtn = document.getElementById('inline-toggle-markdown');
    let markdownMode = false;
    let markdownPreviewTimer = null;

    let lexicalEditor = null;
    if (editorContainer) {
      try {
        lexicalEditor = createInlineEditor(editorContainer, {
          onChange: onLexicalChange,
          onKeyDown: handleEditorKeyDown,
          onEnterKey: handleEditorEnterKey,
          onUploadStateChange: handleUploadStateChange
        });
      } catch (e) {
        console.error('CreativeRowEditor: Failed to create inline editor', e);
      }
    }

    // Initialize queue with current user ID to prevent cross-account data leakage
    try {
      const currentUserId = document.body.dataset.currentUserId;
      if (apiQueue) {
        apiQueue.initialize(currentUserId);
        apiQueue.start();
      } else {
        console.error('CreativeRowEditor: apiQueue is undefined');
      }
    } catch (e) {
      console.error('CreativeRowEditor: Error initializing apiQueue:', e);
    }

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
    let originalProgress = 0;
    let originalOriginId = '';
    let isDirty = false;
    let completionCascadePending = false;
    let editingPingInterval = null;

    function stopEditingPing() {
      if (editingPingInterval) {
        clearInterval(editingPingInterval);
        editingPingInterval = null;
      }
    }

    // Clean up editing ping on Turbo navigation to prevent interval leak
    document.addEventListener('turbo:before-cache', () => stopEditingPing());

    const destroyedCreativeIds = new Set();

    function formatProgressDisplay(value) {
      return isProgressComplete(value) ? progressCompleteLabel : progressIncompleteLabel;
    }

    function readProgressValue() {
      if (!progressInput) return 0;
      return progressInput.checked ? 1 : 0;
    }

    function progressValueChanged() {
      if (!progressInput) return false;
      return progressValueChangedFrom(originalProgress, progressInput.checked);
    }

    function setProgressState(value) {
      if (!progressInput) return;
      const complete = isProgressComplete(value);
      progressInput.checked = complete;
      if (progressValue) {
        progressValue.textContent = formatProgressDisplay(value);
      }
    }

    function updateProgressInputAvailability(value) {
      if (!progressInput) return;
      const hasChildren = currentRowHasChildren();
      const complete = isProgressComplete(value);
      const shouldDisable = hasChildren && complete;
      progressInput.disabled = shouldDisable;
      if (progressHiddenInput) {
        progressHiddenInput.disabled = false;
        progressHiddenInput.value = shouldDisable ? '1' : '0';
      }
    }

    function treeRowElement(node) {
      return node && node.closest ? node.closest('creative-tree-row') : null;
    }

    function currentRowHasChildren() {
      const row = currentRowElement || (currentTree ? treeRowElement(currentTree) : null);
      if (!row) return false;
      return !!(row.hasChildren || row.getAttribute?.('has-children'));
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
      if (Object.prototype.hasOwnProperty.call(data, 'content_type')) {
        setRowDatasetValue(row, 'contentType', data.content_type ?? '');
      }
      if (Object.prototype.hasOwnProperty.call(data, 'markdown_source')) {
        setRowDatasetValue(row, 'markdownSource', data.markdown_source ?? '');
      }
      if (Object.prototype.hasOwnProperty.call(data, 'markdown_editor')) {
        setRowDatasetValue(row, 'markdownEditor', data.markdown_editor ?? '');
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
        progress: Number.isNaN(progressValue) ? 0 : progressValue,
        content_type: row.dataset?.contentType || null,
        markdown_editor: row.dataset?.markdownEditor || null,
        markdown_source: row.dataset?.markdownSource || null
      };
    }

    function isMarkdownEmpty(md) {
      return !md || md.trim().length === 0;
    }

    function activateMarkdownMode(source) {
      markdownMode = true;
      if (contentTypeInput) contentTypeInput.value = 'markdown';
      if (markdownEditorInput) markdownEditorInput.value = 'source';
      if (markdownTextarea) markdownTextarea.value = source || '';
      if (markdownWrapper) markdownWrapper.style.display = '';
      if (editorContainer) editorContainer.style.display = 'none';
      if (markdownPreview) markdownPreview.innerHTML = source ? renderMarkdown(source) : '';
      if (toggleMarkdownBtn) {
        toggleMarkdownBtn.textContent = toggleMarkdownBtn.dataset.labelRichtext || 'Rich Text';
        toggleMarkdownBtn.classList.add('active');
      }
      if (markdownTextarea) markdownTextarea.focus();
    }

    function deactivateMarkdownMode() {
      markdownMode = false;
      if (contentTypeInput) contentTypeInput.value = 'html';
      if (markdownEditorInput) markdownEditorInput.value = '';
      if (markdownSourceInput) markdownSourceInput.value = '';
      if (markdownWrapper) markdownWrapper.style.display = 'none';
      if (editorContainer) editorContainer.style.display = '';
      if (toggleMarkdownBtn) {
        toggleMarkdownBtn.textContent = toggleMarkdownBtn.dataset.labelMarkdown || 'MD';
        toggleMarkdownBtn.classList.remove('active');
      }
    }

    function syncMarkdownToForm() {
      if (!markdownMode) return;
      const md = markdownTextarea ? markdownTextarea.value : '';
      if (markdownSourceInput) markdownSourceInput.value = md;
      if (descriptionInput) descriptionInput.value = renderMarkdown(md);
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

      // Markdown is the canonical storage format for BOTH editors now. Which
      // surface opens is decided by the persisted editor preference: only
      // explicitly rich-authored Markdown reopens in Lexical; "source" and
      // legacy (no preference) Markdown reopen in the advanced textarea.
      const isMarkdown = data.content_type === 'markdown';
      const useTextarea = isMarkdown && data.markdown_editor !== 'rich';
      if (useTextarea) {
        activateMarkdownMode(data.markdown_source || '');
        // Also load Lexical with HTML for fallback/switching
        lexicalEditor.load(content, `creative-${creativeId}-${Date.now()}`);
      } else {
        deactivateMarkdownMode();
        if (isMarkdown) {
          // Rich-authored Markdown: prime the hidden fields so a no-edit save
          // (move, progress toggle) preserves Markdown canonical instead of
          // demoting back to HTML before the first Lexical change fires.
          if (contentTypeInput) contentTypeInput.value = 'markdown';
          if (markdownSourceInput) markdownSourceInput.value = data.markdown_source || '';
          if (markdownEditorInput) markdownEditorInput.value = 'rich';
        }
        lexicalEditor.load(content, `creative-${creativeId}-${Date.now()}`);
      }

      pendingSave = false;
      // Dirty detection is HTML-based for the rich surface (compares the editor's
      // HTML projection), and Markdown-source-based for the textarea surface.
      originalContent = useTextarea ? (data.markdown_source || '') : content;
      isDirty = false;
      setSaveStatus('');
      const progressNumber = Number(data.progress ?? 0);
      const normalizedProgress = Number.isNaN(progressNumber) ? 0 : progressNumber;
      setProgressState(normalizedProgress);
      updateProgressInputAvailability(normalizedProgress);
      completionCascadePending = false;
      const fallbackParent = tree?.dataset?.parentId || '';
      parentInput.value = data.parent_id ?? fallbackParent ?? '';
      beforeInput.value = '';
      afterInput.value = '';
      if (childInput) childInput.value = '';
      const originId = data.origin_id || '';
      if (originIdInput) {
        originIdInput.value = originId;
      }
      originalOriginId = originId;
      if (linkBtn) linkBtn.style.display = originId ? 'none' : '';
      if (unlinkBtn) unlinkBtn.style.display = originId ? '' : 'none';
      const effectiveParent = parentInput.value;
      if (unconvertBtn) unconvertBtn.style.display = effectiveParent ? '' : 'none';
      originalProgress = normalizedProgress;
      // Focus the Lexical editor whenever it is the active surface. Gating on
      // `!isMarkdown` was correct when `content_type === 'markdown'` always meant
      // the textarea surface, but rich-authored Markdown now reopens in Lexical
      // (markdown_editor === 'rich'), so use `!useTextarea` to also focus it.
      // The textarea surface focuses itself in activateMarkdownMode().
      if (!useTextarea) {
        lexicalEditor.focus();
      }
      updateActionButtonStates();
      // Reload metadata if the popup is open
      if (isMetadataPopupVisible()) {
        if (data.data !== undefined) {
          // Use data already fetched from API response — avoids extra request
          const yamlStr = yaml.dump(data.data || {}, { lineWidth: -1 });
          metadataEditor.value = yamlStr;
        } else {
          loadMetadataForCreative(creativeId);
        }
      }
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
      if (archiveBtn) {
        archiveBtn.disabled = !hasCreativeId;
        // Toggle label between Archive / Restore based on creative state
        const targetRow = hasCreativeId ? document.querySelector(`creative-tree-row[creative-id="${form.dataset.creativeId}"]`) : null;
        const isArchived = targetRow?.hasAttribute('archived');
        archiveBtn.textContent = isArchived ? (archiveBtn.dataset.restoreLabel || 'Restore') : (archiveBtn.dataset.archiveLabel || 'Archive');
      }
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

      // Notify sync controller that editing started + periodic ping
      const editCreativeId = form.dataset.creativeId || currentRowElement?.getAttribute('creative-id');
      if (editCreativeId) {
        const parsedId = parseInt(editCreativeId, 10);
        document.dispatchEvent(new CustomEvent('creative-editing:start', {
          detail: { creativeId: parsedId }
        }));
        if (editingPingInterval) clearInterval(editingPingInterval);
        editingPingInterval = setInterval(() => {
          document.dispatchEvent(new CustomEvent('creative-editing:start', {
            detail: { creativeId: parsedId }
          }));
        }, 3000);
      }
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

      if (!addCreativeShortcutHandler) {
        addCreativeShortcutHandler = function (event) {
          if (event.defaultPrevented || event.isComposing) return;
          if (event.key !== 'Enter' || event.altKey || event.ctrlKey || event.metaKey || event.shiftKey) return;
          const target = event.target;
          const interactiveSelector = 'input, textarea, select, button, a, [contenteditable="true"], [data-lexical-editor-root]';
          if (target && target.closest && target.closest(interactiveSelector)) return;
          if (target && target.isContentEditable) return;
          const addButton = document.querySelector('.creative-actions-row .add-creative-btn, .creative-actions-row .new-root-creative-btn');
          if (!addButton) return;
          event.preventDefault();
          addButton.click();
        };
        document.addEventListener('keydown', addCreativeShortcutHandler);
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

        // Sync markdown form fields before saving
        if (markdownMode) syncMarkdownToForm();

        const isEmpty = markdownMode
          ? isMarkdownEmpty(markdownTextarea?.value)
          : isHtmlEmpty(descriptionInput.value);
        if (isEmpty) {
          pendingSave = false;
          return Promise.resolve();
        }

        const method = methodInput.value === 'patch' ? 'PATCH' : 'POST';
        pendingSave = false;
        if (!form.action) return Promise.resolve();
        saving = true;
        // Only reflect this save's outcome while the editor is still bound to the
        // creative it started on. If the user navigates to another row mid-flight
        // (move() reattaches the shared #inline-save-status span to the new row),
        // a late completion must not mislabel the newly opened row.
        const applySaveStatus = function (state) {
          if (tree === currentTree) setSaveStatus(state);
        };
        applySaveStatus('saving');

        // Capture values being saved to update dirty state on success
        // NOTE: `let` (not `const`) — when the server rewrites markdown_source
        // (e.g. data: URI → blob path) we reassign below.
        let savedContent = markdownMode ? (markdownTextarea?.value || '') : descriptionInput.value;
        const shouldPersistProgress = progressValueChanged();
        const savedProgress = shouldPersistProgress ? readProgressValue() : progressBaselineValueFrom(originalProgress);
        const savedOriginId = originIdInput ? originIdInput.value : '';
        const cascadeProgressUpdate = completionCascadePending;
        const progressInputsDisabled = progressInput?.disabled ?? false;
        const hiddenProgressDisabled = progressHiddenInput?.disabled ?? false;

        if (!shouldPersistProgress) {
          if (progressInput) progressInput.disabled = true;
          if (progressHiddenInput) progressHiddenInput.disabled = true;
        }

        savePromise = creativesApi.save(form.action, method, form).then(function (r) {
          if (!r.ok) {
            applySaveStatus('error');
            return r;
          }
          return r.text().then(function (text) {
            try { return text ? JSON.parse(text) : {}; } catch (e) { return {}; }
          }).then(function (data) {
            // Sync rewritten markdown source back into the textarea/hidden input.
            // Server rewrites inline data: URIs in markdown_source to blob paths so
            // re-saves don't re-import the same image. If the user typed during the
            // request, merge the substitutions into the live textarea so the next
            // save still carries blob paths instead of re-importing the data URI.
            if (markdownMode && data && typeof data.markdown_source === 'string'
                && data.markdown_source !== savedContent && markdownTextarea) {
              const reconciled = reconcileMarkdownSource(
                savedContent, data.markdown_source, markdownTextarea.value
              );
              if (reconciled !== null && reconciled !== markdownTextarea.value) {
                markdownTextarea.value = reconciled;
                syncMarkdownToForm();
              }
              if (reconciled !== null) {
                savedContent = data.markdown_source;
              }
            }

            // Update dirty state to reflect successful save
            originalContent = savedContent;
            if (shouldPersistProgress) {
              originalProgress = savedProgress;
            }
            originalOriginId = savedOriginId;

            // If current values match what was just saved, clear dirty flag
            const currentContent = markdownMode ? (markdownTextarea?.value || '') : descriptionInput.value;
            if (currentContent === savedContent &&
              readProgressValue() === savedProgress &&
              originIdInput.value === savedOriginId) {
              isDirty = false;
            }

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
                  const creativeLink = `/creatives/${data.id}`;
                  rowEl.setAttribute('link-url', creativeLink);
                  rowEl.linkUrl = creativeLink;
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
            if (cascadeProgressUpdate && tree) {
              refreshChildren(tree);
              completionCascadePending = false;
            }

            // Delete removed attachments after successful save
            if (lexicalEditor && typeof lexicalEditor.getDeletedAttachments === 'function') {
              const deletedIds = lexicalEditor.getDeletedAttachments();
              if (deletedIds && deletedIds.length > 0) {
                deletedIds.forEach(deleteAttachment);
              }
            }
            updateActionButtonStates();
            // Only announce "saved" when the current buffer still matches what we
            // just persisted. Text edits during the in-flight save keep isDirty
            // true; a non-text change (e.g. a second progress toggle) re-arms
            // pendingSave while this early-returns on the shared promise. Either
            // means the latest value isn't persisted, so show "pending".
            applySaveStatus((isDirty || pendingSave) ? 'pending' : 'saved');
          });
        }).catch(function (err) {
          // Preserve existing rejection propagation; only surface save status.
          applySaveStatus('error');
          throw err;
        }).finally(function () {
          saving = false;
          if (!shouldPersistProgress) {
            if (progressInput) progressInput.disabled = progressInputsDisabled;
            if (progressHiddenInput) progressHiddenInput.disabled = hiddenProgressDisabled;
          }
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

      // Notify sync controller that editing stopped
      stopEditingPing();
      const editCreativeId = form.dataset.creativeId;
      document.dispatchEvent(new CustomEvent('creative-editing:stop', {
        detail: { creativeId: editCreativeId ? parseInt(editCreativeId, 10) : null }
      }));

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

      // Try to use cached data from the row first for instant loading
      // BUT only if we have actual content in the dataset
      // We must check the DOM element directly because inlinePayloadFromTree defaults missing values
      const row = treeRowElement(tree);
      const hasDescription = hasDatasetValue(row, 'descriptionRawHtml') || hasDatasetValue(row, 'descriptionHtml');
      const hasProgress = hasDatasetValue(row, 'progressValue');

      const inlineData = inlinePayloadFromTree(tree);

      // CRITICAL: Require BOTH description AND progress to be present in the dataset
      // If either is missing, inlinePayloadFromTree defaults it (e.g. progress=0),
      // which would overwrite the real value on the server if we saved it.
      if (inlineData && inlineData.id && hasDescription && hasProgress) {
        console.log('✅ Using cached data for creative', id, '- NO API CALL');
        applyCreativeData(inlineData, tree);
        return;
      }

      // Fallback: if no cached data or incomplete data, fetch from API
      // This happens for lazily loaded children or rows without inline_editor_payload
      console.warn('⚠️ Incomplete or missing cached data for creative', id, '- making API call');
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
     * IMPORTANT: Waits for pending uploads to complete before queueing
     * @param {Element} tree - The tree element whose row should be updated (defaults to currentTree)
     */
    async function queueSaveIfDirty(tree = currentTree) {
      // Check both isDirty (text changes) and pendingSave (progress/structure changes)
      if (!isDirty && !pendingSave) return;

      const creativeId = form.dataset?.creativeId;
      if (!creativeId) return;

      // Skip save for already-destroyed creatives (prevents 404 after deletion)
      if (destroyedCreativeIds.has(String(creativeId))) {
        isDirty = false;
        pendingSave = null;
        return;
      }

      // CRITICAL: Capture ALL values BEFORE awaiting, because the editor may switch
      // to a different creative while we're waiting for uploads
      // Both editor surfaces persist Markdown now. The textarea surface
      // (markdownMode) syncs its value to the hidden fields here; the rich
      // surface already kept them current via onLexicalChange/applyCreativeData.
      if (markdownMode) syncMarkdownToForm();
      const capturedContentType = contentTypeInput ? contentTypeInput.value : 'html';
      const isMarkdownSave = capturedContentType === 'markdown';
      let currentContent = descriptionInput.value;
      let currentProgress = readProgressValue();
      let shouldPersistProgress = progressValueChanged();
      const currentParentId = tree.dataset.parentId || '';
      const currentBeforeId = tree.previousElementSibling ? creativeIdFrom(tree.previousElementSibling) : '';
      const currentAfterId = tree.nextElementSibling ? creativeIdFrom(tree.nextElementSibling) : '';
      const startCreativeId = creativeId;
      let capturedMarkdownSource = isMarkdownSave ? (markdownSourceInput ? markdownSourceInput.value : '') : '';
      const capturedMarkdownEditor = markdownEditorInput ? markdownEditorInput.value : '';

      // Prevent saving empty content, matching saveForm behavior
      // This avoids overwriting existing descriptions with empty strings during quick navigation
      const isEmpty = isMarkdownSave
        ? isMarkdownEmpty(capturedMarkdownSource)
        : isHtmlEmpty(currentContent);
      if (isEmpty) {
        pendingSave = false;
        return;
      }

      // CRITICAL: Wait for uploads to complete before queueing
      // But we already captured the values above, so switching editors won't affect us
      await waitForUploads();

      // If we are still on the same creative (e.g. move awaited us), refresh the content
      // This ensures we capture the final HTML with signed IDs instead of blob URLs.
      // Markdown saves regenerate description from creative[markdown_source] server-side,
      // so we must re-sync and re-capture the latest textarea value too — otherwise edits
      // made during the upload wait get overwritten by the stale pre-wait source.
      if (form.dataset.creativeId === startCreativeId) {
        if (markdownMode) {
          syncMarkdownToForm();
          capturedMarkdownSource = markdownSourceInput ? markdownSourceInput.value : '';
        } else if (isMarkdownSave && markdownSourceInput) {
          // Rich surface: re-capture any Markdown produced by edits during the wait.
          capturedMarkdownSource = markdownSourceInput.value;
        }
        currentContent = descriptionInput.value;
        currentProgress = readProgressValue();
        shouldPersistProgress = progressValueChanged();
      }

      // Build request body
      // Note: before_id and after_id must be top-level params, not nested under creative[]
      // because CreativesController reads params[:before_id] and params[:after_id] for positioning
      const body = {
        'creative[description]': currentContent,
        'creative[content_type_input]': capturedContentType
      };
      if (isMarkdownSave) {
        body['creative[markdown_source]'] = capturedMarkdownSource;
        if (capturedMarkdownEditor) {
          body['creative[markdown_editor]'] = capturedMarkdownEditor;
        }
      }

      if (shouldPersistProgress) {
        body['creative[progress]'] = currentProgress;
      }

      // Always include parent_id, even if empty (for moving to root)
      body['creative[parent_id]'] = currentParentId;

      if (currentBeforeId) {
        body['before_id'] = currentBeforeId;  // Top-level, not creative[before_id]
      }
      if (currentAfterId) {
        body['after_id'] = currentAfterId;  // Top-level, not creative[after_id]
      }

      // Update row dataset immediately to keep cached data fresh
      // IMPORTANT: Use the passed tree parameter, not currentTree, because currentTree
      // may have already been updated to point to a different creative
      if (tree) {
        const row = treeRowElement(tree);
        if (row) {
          row.dataset.descriptionHtml = currentContent;
          row.descriptionHtml = currentContent;
          row.dataset.descriptionRawHtml = currentContent;
          if (shouldPersistProgress) {
            row.dataset.progressValue = String(currentProgress);
          }
          row.dataset.contentType = capturedContentType;
          row.dataset.markdownSource = isMarkdownSave ? capturedMarkdownSource : '';
          // Persist which surface authored this save so a row re-opened from this
          // cached payload (before any full GET refresh) reopens in the right
          // editor — without it, rich-authored Markdown falls back to the textarea.
          row.dataset.markdownEditor = isMarkdownSave ? capturedMarkdownEditor : '';
          if (currentParentId) {
            tree.dataset.parentId = currentParentId;
            row.parentId = currentParentId;
          }
          // Trigger Lit component re-render to show updated values
          row.requestUpdate?.();
        }
      }

      // Capture deleted attachments to delete AFTER successful save
      // Store as data (not callback) so it can be serialized to localStorage
      let deletedAttachmentIds = null;
      if (lexicalEditor && typeof lexicalEditor.getDeletedAttachments === 'function') {
        deletedAttachmentIds = lexicalEditor.getDeletedAttachments();
        // Only include if there are actual IDs to delete
        if (deletedAttachmentIds && deletedAttachmentIds.length === 0) {
          deletedAttachmentIds = null;
        }
      }

      // Queue the save request
      // Store deletedAttachmentIds as data, not as callback, so it can be serialized
      // Capture per-enqueue values for the onSuccess closure so concurrent edits
      // on a different creative don't get clobbered when the response comes back.
      const onSuccessCreativeId = startCreativeId;
      const onSuccessSavedMarkdown = isMarkdownSave ? capturedMarkdownSource : null;
      const onSuccessTree = tree;
      apiQueue.enqueue({
        path: `/creatives/${creativeId}`,
        method: 'PATCH',
        body: body,
        dedupeKey: `creative_${creativeId}`,
        deletedAttachmentIds: deletedAttachmentIds,  // Store as data for serialization
        onSuccess: function (data) {
          if (!isMarkdownSave || !data || typeof data.markdown_source !== 'string') return;
          if (data.markdown_source === onSuccessSavedMarkdown) return;

          // Update the row dataset cache regardless of which creative is active now,
          // so a later loadCreative() for this row picks up the rewritten source.
          if (onSuccessTree) {
            const row = treeRowElement(onSuccessTree);
            if (row && row.dataset.markdownSource === onSuccessSavedMarkdown) {
              row.dataset.markdownSource = data.markdown_source;
              row.requestUpdate?.();
            }
          }

          // Merge the data: URI -> blob path substitutions into the live textarea,
          // even if the user typed during the queued save. We still require the
          // same creative to be open (race-safe across editor switches).
          if (form.dataset.creativeId === onSuccessCreativeId
              && markdownMode
              && markdownTextarea) {
            const reconciled = reconcileMarkdownSource(
              onSuccessSavedMarkdown, data.markdown_source, markdownTextarea.value
            );
            if (reconciled !== null && reconciled !== markdownTextarea.value) {
              markdownTextarea.value = reconciled;
              syncMarkdownToForm();
            }
            if (reconciled !== null) {
              originalContent = data.markdown_source;
            }
          }
        }
      });
      // console.warn('apiQueue.enqueue disabled for debugging');

      // Reset dirty state
      originalContent = currentContent;
      if (shouldPersistProgress) {
        originalProgress = currentProgress;
      }
      isDirty = false;
      pendingSave = false;
      clearTimeout(saveTimer);
    }

    async function move(delta) {
      if (!currentTree) return;
      const trees = Array.from(document.querySelectorAll('.creative-tree'));
      const index = trees.indexOf(currentTree);
      if (index === -1) return;
      const target = trees[index + delta];
      if (!target) return;

      const prev = currentTree;
      const wasNew = !form.dataset.creativeId;
      const prevParent = parentInput.value;

      // Queue save if dirty (non-blocking unless uploading)
      // CRITICAL: Pass 'prev' tree explicitly because currentTree will be updated immediately after
      if (!wasNew) {
        if (uploadsPending) {
          // If uploading, we MUST wait for the upload to finish and the save to capture the new URL
          // otherwise we risk saving the blob URL and losing the attachment
          await queueSaveIfDirty(prev);
        } else {
          queueSaveIfDirty(prev);
        }
      }

      // Update UI immediately
      currentTree = target;
      currentRowElement = treeRowElement(target);
      syncInlineEditorPadding(currentRowElement);
      hideRow(target);
      attachTemplate(target);
      template.style.display = 'block';

      // Handle new creative cleanup or show previous row
      const focusAfterMove = () => {
        if (delta < 0 && lexicalEditor.focusAtStart) {
          lexicalEditor.focusAtStart();
        } else {
          lexicalEditor.focus();
        }
      };

      // Notify editing stopped on previous creative
      stopEditingPing();
      const prevCreativeId = prev.dataset?.id || form.dataset?.creativeId;
      if (prevCreativeId) {
        document.dispatchEvent(new CustomEvent('creative-editing:stop', {
          detail: { creativeId: parseInt(prevCreativeId, 10) }
        }));
      }

      if (wasNew) {
        // For new creatives, still need to save or cleanup
        beforeNewOrMove(wasNew, prev, prevParent).then(() => {
          loadCreative(target);
          focusAfterMove();
          // Notify editing started on new creative + start ping
          const newCreativeId = target.dataset?.id || currentRowElement?.getAttribute('creative-id');
          if (newCreativeId) {
            const parsedNewId = parseInt(newCreativeId, 10);
            document.dispatchEvent(new CustomEvent('creative-editing:start', {
              detail: { creativeId: parsedNewId }
            }));
            stopEditingPing();
            editingPingInterval = setInterval(() => {
              document.dispatchEvent(new CustomEvent('creative-editing:start', {
                detail: { creativeId: parsedNewId }
              }));
            }, 3000);
          }
        });
      } else {
        // For existing creatives, show the row and refresh if needed
        if (prev.querySelector('.creative-row')) {
          showRow(prev);
        }
        loadCreative(target);
        focusAfterMove();
        // Notify editing started on new creative + start ping
        const newCreativeId = target.dataset?.id || currentRowElement?.getAttribute('creative-id');
        if (newCreativeId) {
          const parsedNewId = parseInt(newCreativeId, 10);
          document.dispatchEvent(new CustomEvent('creative-editing:start', {
            detail: { creativeId: parsedNewId }
          }));
          stopEditingPing();
          editingPingInterval = setInterval(() => {
            document.dispatchEvent(new CustomEvent('creative-editing:start', {
              detail: { creativeId: parsedNewId }
            }));
          }, 3000);
        }
      }
      updateActionButtonStates();
    }

    async function addNew() {
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

      // Queue save if dirty (non-blocking unless uploading)
      // CRITICAL: Pass 'prev' tree explicitly
      if (!wasNew) {
        if (uploadsPending) {
          await queueSaveIfDirty(prev);
        } else {
          queueSaveIfDirty(prev);
        }
      }

      // Notify editing stopped on previous creative
      stopEditingPing();
      const prevEditId = prev.dataset?.id || form.dataset?.creativeId;
      if (prevEditId) {
        document.dispatchEvent(new CustomEvent('creative-editing:stop', {
          detail: { creativeId: parseInt(prevEditId, 10) }
        }));
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

    async function addChild() {
      if (!currentTree) return;
      const prev = currentTree;
      const wasNew = !form.dataset.creativeId;
      const prevParent = parentInput.value;

      // Queue save if dirty (non-blocking unless uploading)
      // CRITICAL: Pass 'prev' tree explicitly
      if (!wasNew) {
        if (uploadsPending) {
          await queueSaveIfDirty(prev);
        } else {
          queueSaveIfDirty(prev);
        }
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

      // Mark this creative as destroyed to prevent any future saves (including
      // Lexical onChange callbacks that may fire after deletion)
      destroyedCreativeIds.add(String(id));

      // CRITICAL: Remove any pending saves for this creative from the queue
      if (apiQueue) {
        apiQueue.removeByDedupeKey(`creative_${id}`);
      }

      creativesApi.destroy(id, withChildren).then(() => {
        const destroyedIds = [String(id)];
        if (withChildren) {
          const childrenContainer = document.getElementById("creative-children-" + id);
          if (childrenContainer) {
            childrenContainer.querySelectorAll('creative-tree-row').forEach(row => {
              const cid = row.getAttribute('creative-id');
              if (cid) destroyedIds.push(cid);
            });
          }
        }
        document.dispatchEvent(new CustomEvent('creative-destroyed', {
          detail: { creativeIds: destroyedIds }
        }));
        const parentTree = parentId ? document.getElementById(`creative-${parentId}`) : null;
        const childrenTree = document.getElementById("creative-children-" + id)
        if (!withChildren && childrenTree && parentTree) {
          refreshChildren(parentTree).then(() => {
            if (parentTree) refreshRow(parentTree);
          });
        } else {
          document.getElementById("creative-children-" + id)?.remove();
        }
        // Clear dirty state so move() doesn't try to save the just-deleted creative
        isDirty = false;
        pendingSave = null;
        move(1);
        removeTreeElement(tree);
      });
    }

    function linkExistingCreative() {
      if (!currentTree || !form.dataset.creativeId) return;

      const modal = document.getElementById('link-creative-modal')
      const controller = application.getControllerForElementAndIdentifier(modal, 'link-creative')
      if (controller) {
        controller.open(linkBtn?.getBoundingClientRect(), (item) => {
          creativesApi.linkExisting(form.dataset.creativeId, item.id).then(() => {
            refreshChildren(currentTree).then(() => refreshRow(currentTree));
          });
        });
      }
    }

    function resetOriginTracking() {
      if (originIdInput) originIdInput.value = '';
      originalOriginId = '';
      if (linkBtn) linkBtn.style.display = '';
      if (unlinkBtn) unlinkBtn.style.display = 'none';
    }

    function startNew(parentId, container, insertBefore, beforeId = '', afterId = '', childId = '') {
      resetOriginTracking();
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
        const iconSource = document.querySelector('creative-tree-row[data-edit-icon-html]') || document.getElementById('creatives');
        if (iconSource) {
          if (iconSource.dataset.editIconHtml) {
            rowComponent.dataset.editIconHtml = iconSource.dataset.editIconHtml;
            rowComponent.editIconHtml = iconSource.dataset.editIconHtml;
          }
          if (iconSource.dataset.editOffIconHtml) {
            rowComponent.dataset.editOffIconHtml = iconSource.dataset.editOffIconHtml;
            rowComponent.editOffIconHtml = iconSource.dataset.editOffIconHtml;
          }
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
          resetOriginTracking();
          deactivateMarkdownMode();
          descriptionInput.value = '';
          lexicalEditor.reset(`new-${Date.now()}`);
          setProgressState(0);
          originalProgress = 0;
          if (unconvertBtn) unconvertBtn.style.display = 'none';
          pendingSave = false;
          isDirty = false;
          // The status span is shared across rows; clear the previous row's
          // "saved"/"failed" label so a blank new row doesn't inherit it.
          setSaveStatus('');
          lexicalEditor.focus();
          updateActionButtonStates();
          document.dispatchEvent(new CustomEvent('creative-editing:start', {
            detail: { creativeId: null }
          }));
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
      // Skip scheduling save for already-destroyed creatives
      const creativeId = form.dataset?.creativeId;
      if (creativeId && destroyedCreativeIds.has(String(creativeId))) return;

      pendingSave = true;
      // A prior "saved"/"failed" label would otherwise claim the freshly edited
      // buffer is persisted during the 5s debounce window, so reflect the pending
      // save the moment the buffer diverges from what was last stored. The request
      // hasn't started yet, so this is "pending" (waiting), not "saving".
      if (isDirty) setSaveStatus('pending');
      clearTimeout(saveTimer);
      saveTimer = setTimeout(saveForm, 5000);
    }

    function onLexicalChange(payload) {
      if (markdownMode) return; // Ignore Lexical changes when the textarea is active
      const html = (payload && payload.html) || '';
      const markdown = (payload && payload.markdown) || '';
      descriptionInput.value = html;
      // The rich editor is now a Markdown-canonical surface: persist the Markdown
      // projection (text color/background as normalized <span> fragments) and
      // record that the rich surface authored it, so it reopens in Lexical.
      if (contentTypeInput) contentTypeInput.value = 'markdown';
      if (markdownSourceInput) markdownSourceInput.value = markdown;
      if (markdownEditorInput) markdownEditorInput.value = 'rich';
      // Mark as dirty if the HTML projection changed from original
      isDirty = (html !== originalContent);
      scheduleSave();
    }

    function onMarkdownTextareaInput() {
      const md = markdownTextarea.value;
      syncMarkdownToForm();
      isDirty = (md !== originalContent);
      scheduleSave();
      // Debounced live preview
      clearTimeout(markdownPreviewTimer);
      markdownPreviewTimer = setTimeout(() => {
        if (markdownPreview) markdownPreview.innerHTML = renderMarkdown(md);
      }, 300);
    }

    // Intercepts Shift+Enter via capture-phase keydown on Lexical's root element.
    // Returning true triggers preventDefault + stopImmediatePropagation.
    // Shift+Enter → addNew (save & add next)
    // Bare Enter → newline (handled by Lexical)
    function handleEditorEnterKey(event, editorInstance) {
      addNew();
      return true; // handled — suppress default behavior
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
        // atStart must reflect the start of the whole document, not just offset 0
        // of the current node — otherwise the start of a second paragraph (e.g.
        // right after pressing Enter) is mistaken for the top and ArrowUp jumps
        // to the row above instead of moving the cursor up. See isSelectionAtDocumentStart.
        atStart = isSelectionAtDocumentStart(selection);
        atEnd = isSelectionAtDocumentEnd(selection);
      });

      if ((isArrowUp || isCtrlP) && atStart) {
        event.preventDefault();
        // Don't call saveForm() here - move() handles async saving via queueSaveIfDirty
        move(-1);
        requestAnimationFrame(() => lexicalEditor.focus());
        return;
      }

      if ((isArrowDown || isCtrlN) && atEnd) {
        event.preventDefault();
        // Don't call saveForm() here - move() handles async saving via queueSaveIfDirty
        move(1);
        requestAnimationFrame(() => lexicalEditor.focus());
      }
    }

    if (progressInput) {
      progressInput.addEventListener('change', function () {
        if (progressValue) {
          progressValue.textContent = formatProgressDisplay(readProgressValue());
        }
        completionCascadePending = false;
        const hasChildren = currentRowHasChildren();
        const shouldCascade = hasChildren && progressValueChanged();
        if (shouldCascade) {
          completionCascadePending = true;
          const alertMessage = progressInput.dataset.childrenAlertMessage;
          if (alertMessage) {
            alertDialog(alertMessage);
          }
        }
        updateProgressInputAvailability(readProgressValue());
        // Save immediately on checkbox change to prevent losing the last toggle
        // when the user navigates away before the debounce timer fires.
        pendingSave = true;
        clearTimeout(saveTimer);
        saveForm();
      });
    }

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
      // Don't call saveForm() here - move() handles async saving via queueSaveIfDirty
      move(-1);
    });
    downBtn.addEventListener('click', function () {
      // Don't call saveForm() here - move() handles async saving via queueSaveIfDirty
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

    if (archiveBtn) {
      archiveBtn.addEventListener('click', async function () {
        const creativeId = form.dataset.creativeId;
        if (!creativeId) return;
        const row = document.querySelector(`creative-tree-row[creative-id="${creativeId}"]`);
        const isArchived = row?.hasAttribute('archived');
        const confirmMsg = isArchived ? archiveBtn.dataset.restoreConfirm : archiveBtn.dataset.confirm;

        if (await confirmDialog(confirmMsg)) {
          const apiCall = isArchived ? creativesApi.unarchive(creativeId) : creativesApi.archive(creativeId);
          apiCall.then(res => {
            if (res.ok) {
              if (!isArchived) {
                // Archiving: remove from view
                const childrenContainer = document.getElementById(`creative-children-${creativeId}`);
                if (childrenContainer) childrenContainer.remove();
                if (row) row.remove();
              } else {
                // Restoring: reload tree to show updated state
                const treeEl = document.querySelector('[data-controller="creatives--tree"]');
                if (treeEl) {
                  treeEl.innerHTML = '';
                  delete treeEl.dataset.loaded;
                  const ctrl = window.Stimulus?.getControllerForElementAndIdentifier(treeEl, 'creatives--tree');
                  if (ctrl) ctrl.load();
                }
              }
              closeEditor();
            }
          });
        }
      });
    }

    if (deleteBtn) {
      deleteBtn.addEventListener('click', async function () {
        if (await confirmDialog(deleteBtn.dataset.confirm, { danger: true })) deleteCurrent(false);
      });
    }

    if (deleteWithChildrenBtn) {
      deleteWithChildrenBtn.addEventListener('click', async function () {
        if (await confirmDialog(deleteWithChildrenBtn.dataset.confirm, { danger: true })) deleteCurrent(true);
      });
    }

    // Expose for testing
    window.creativeRowEditor = {
      setUploadsPending: (pending) => {
        uploadsPending = pending;
        if (pending) {
          uploadCompletionPromise = new Promise((resolve) => {
            resolveUploadCompletion = resolve;
          });
        } else if (resolveUploadCompletion) {
          resolveUploadCompletion();
          uploadCompletionPromise = null;
          resolveUploadCompletion = null;
        }
        handleUploadStateChange(pending);
      },
      resolveUploadCompletion: () => {
        if (resolveUploadCompletion) {
          resolveUploadCompletion();
          uploadsPending = false;
          uploadCompletionPromise = null;
          resolveUploadCompletion = null;
          handleUploadStateChange(false);
        }
      },
      isUploadPending: () => uploadsPending
    };

    if (linkBtn) {
      linkBtn.addEventListener('click', linkExistingCreative);
    }

    if (unlinkBtn) {
      unlinkBtn.addEventListener('click', async function () {
        if (await confirmDialog(unlinkBtn.dataset.confirm, { danger: true })) deleteCurrent(false);
      });
    }

    if (unconvertBtn) {
      unconvertBtn.addEventListener('click', async function () {
        const creativeId = form.dataset.creativeId;
        if (!creativeId) return;
        const confirmText = unconvertBtn.dataset.confirm;
        if (confirmText && !(await confirmDialog(confirmText))) return;
        const errorMessage = unconvertBtn.dataset.error || 'Failed to unconvert.';
        unconvertBtn.disabled = true;
        saveForm()
          .then(function (saveResponse) {
            if (saveResponse && saveResponse.ok === false) {
              return saveResponse
                .json()
                .catch(function () { return {}; })
                .then(function (data) {
                  alertDialog(data && data.error ? data.error : errorMessage);
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
                alertDialog(data && data.error ? data.error : errorMessage);
              });
          })
          .catch(function (error) {
            if (error && error._handled) return;
            alertDialog(errorMessage);
          })
          .finally(function () {
            unconvertBtn.disabled = false;
          });
      });
    }

    // Metadata editor handlers
    function loadMetadataForCreative(creativeId) {
      if (!creativeId || !metadataPopup || !metadataEditor) return;
      creativesApi.get(creativeId)
        .then(function (data) {
          const metadataObj = data.data || {};
          const yamlStr = yaml.dump(metadataObj, { lineWidth: -1 });
          metadataEditor.value = yamlStr;
        })
        .catch(function (error) {
          console.error('Failed to load metadata:', error);
          alertDialog('Failed to load metadata');
        });
    }

    function isMetadataPopupVisible() {
      return metadataPopup && metadataPopup.style.display !== 'none';
    }

    if (metadataBtn && metadataPopup && metadataEditor) {
      metadataBtn.addEventListener('click', function () {
        const creativeId = form.dataset.creativeId;
        if (!creativeId) return;

        if (isMetadataPopupVisible()) {
          metadataPopup.style.display = 'none';
          return;
        }

        loadMetadataForCreative(creativeId);
        metadataPopup.style.display = 'block';
      });

      if (metadataCloseBtn) {
        metadataCloseBtn.addEventListener('click', function () {
          metadataPopup.style.display = 'none';
        });
      }

      if (metadataSaveBtn) {
        metadataSaveBtn.addEventListener('click', function () {
          const creativeId = form.dataset.creativeId;
          if (!creativeId) return;

          try {
            // Parse YAML back to JSON
            const yamlStr = metadataEditor.value;
            const parsedData = yaml.load(yamlStr) || {};

            // Send PATCH request
            creativesApi.updateMetadata(creativeId, parsedData)
              .then(function (response) {
                if (response.ok) {
                  metadataPopup.style.display = 'none';
                } else {
                  return response.json().then(function (data) {
                    alertDialog('Failed to save metadata: ' + (data.error || 'Unknown error'));
                  });
                }
              })
              .catch(function (error) {
                console.error('Failed to save metadata:', error);
                alertDialog('Failed to save metadata');
              });
          } catch (error) {
            console.error('YAML parse error:', error);
            alertDialog('Invalid YAML format: ' + error.message);
          }
        });
      }
    }

    // Markdown toggle button
    if (toggleMarkdownBtn) {
      toggleMarkdownBtn.addEventListener('click', async function () {
        if (markdownMode) {
          // Switching from Markdown (advanced textarea) → Rich Text. The Markdown
          // stays canonical; we only flip the authoring surface to rich so it
          // reopens in Lexical, and render it to HTML for the editor view.
          const confirmMsg = toggleMarkdownBtn.dataset.confirmToRichtext;
          if (confirmMsg && !(await confirmDialog(confirmMsg))) return;
          const md = markdownTextarea?.value || '';
          const html = md ? renderMarkdown(md) : '';
          deactivateMarkdownMode();
          descriptionInput.value = html;
          if (md) {
            if (contentTypeInput) contentTypeInput.value = 'markdown';
            if (markdownSourceInput) markdownSourceInput.value = md;
            if (markdownEditorInput) markdownEditorInput.value = 'rich';
          }
          lexicalEditor.load(html, `creative-switch-${Date.now()}`);
          lexicalEditor.focus();
          isDirty = true;
          scheduleSave();
        } else {
          // Switching from Rich Text → Markdown (advanced textarea). Preserve the
          // content by seeding the textarea with the rich surface's current
          // Markdown projection instead of discarding it.
          const currentHtml = descriptionInput.value || '';
          if (!isHtmlEmpty(currentHtml)) {
            const confirmMsg = toggleMarkdownBtn.dataset.confirmToMarkdown;
            if (confirmMsg && !(await confirmDialog(confirmMsg))) return;
          }
          const existingMarkdown = markdownSourceInput ? markdownSourceInput.value : '';
          activateMarkdownMode(existingMarkdown);
          isDirty = true;
          scheduleSave();
        }
      });
    }

    // Markdown textarea input handler
    if (markdownTextarea) {
      markdownTextarea.addEventListener('input', onMarkdownTextareaInput);

      // Support keyboard shortcuts in markdown textarea
      markdownTextarea.addEventListener('keydown', function (event) {
        if (event.key === 'Escape') {
          event.preventDefault();
          hideCurrent();
          return;
        }
        // Shift+Enter → add new sibling (same as Lexical)
        if (event.key === 'Enter' && event.shiftKey) {
          event.preventDefault();
          addNew();
        }
      });
    }
  });
}
