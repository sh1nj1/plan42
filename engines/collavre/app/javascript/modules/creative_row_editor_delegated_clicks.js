import { creativeIdFrom } from './creative_tree_dom';

export function createDelegatedClickHandler(session) {
  return function handleDelegatedClick(event) {
    const target = event.target;
    if (!target || typeof target.closest !== 'function') return;

    const editBtn = target.closest('.edit-inline-btn');
    if (editBtn) {
      event.preventDefault();
      const tree = editBtn.closest('.creative-tree');
      if (tree) session.handleEditButtonClick(tree);
      return;
    }

    const addBtn = target.closest('.add-creative-btn:not(#inline-add):not(#inline-level-down):not(#inline-level-up)');
    if (addBtn) {
      event.preventDefault();
      if (session.template.style.display === 'block') {
        session.hideCurrent();
        return;
      }

      const tree = addBtn.closest('.creative-tree');
      let parentId;
      let container;
      let insertBefore;
      let beforeId = '';

      if (tree) {
        parentId = tree.dataset.id;
        container = tree.querySelector('.creative-children');
        if (!container) {
          container = document.createElement('div');
          container.className = 'creative-children';
          container.id = `creative-children-${parentId}`;
          tree.appendChild(container);
        }
        insertBefore = container.firstElementChild;
        beforeId = insertBefore ? creativeIdFrom(insertBefore) : '';
      } else {
        parentId = addBtn.dataset.parentId || '';
        container = document.getElementById('creatives');
        if (!container) return;
        insertBefore = container.firstElementChild;
        beforeId = insertBefore ? creativeIdFrom(insertBefore) : '';
      }

      session.startNew(parentId, container, insertBefore, beforeId);
      return;
    }

    const newRootBtn = target.closest('.new-root-creative-btn');
    if (newRootBtn) {
      event.preventDefault();
      const container = document.getElementById('creatives');
      if (!container) return;

      if (session.template.style.display === 'block') {
        session.hideCurrent();
        return;
      }

      const insertBefore = container.firstElementChild;
      const beforeId = insertBefore ? creativeIdFrom(insertBefore) : '';
      session.startNew('', container, insertBefore, beforeId);
      return;
    }

    const appendParentBtn = target.closest('.append-parent-btn');
    if (!appendParentBtn) return;

    event.preventDefault();
    const targetId = appendParentBtn.dataset.childId;
    const targetTree = document.getElementById(`creative-${targetId}`);
    if (!targetTree) return;
    const container = targetTree.parentNode;
    session.startNew(
      container.id.startsWith('creative-children-') ? container.id.replace('creative-children-', '') : '',
      container,
      targetTree,
      targetId,
      '',
      targetId
    );
  };
}
