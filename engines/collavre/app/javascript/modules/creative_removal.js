// Link shells display origin descendants, which must survive shell removal.
export function updateRemovalButtons(button, recursiveButton, isLink) {
  if (button) {
    const label = isLink ? button.dataset.removeLinkLabel : button.dataset.deleteLabel;
    if (label) button.textContent = button.title = label;
    const confirmation = isLink ? button.dataset.removeLinkConfirm : button.dataset.deleteConfirm;
    if (confirmation) button.dataset.confirm = confirmation;
  }
  if (recursiveButton) recursiveButton.hidden = isLink;
}

export function destroyedIdsForRemoval(id, withChildren) {
  const ids = [String(id)];
  if (withChildren) {
    document.getElementById(`creative-children-${id}`)?.querySelectorAll('creative-tree-row').forEach(row => {
      const childId = row.getAttribute('creative-id');
      if (childId) ids.push(childId);
    });
  }
  return ids;
}

export function promotesChildrenToRoot({ isLink, withChildren, parentTree, hasChildren, childrenTree }) {
  return !isLink && !withChildren && !parentTree &&
    (hasChildren || !!childrenTree?.querySelector('creative-tree-row'));
}

export function shouldRefreshRemovalParent(isLink, withChildren, childrenTree, parentTree) {
  return !isLink && !withChildren && childrenTree && parentTree;
}
