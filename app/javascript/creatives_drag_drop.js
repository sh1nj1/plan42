if (!window.creativesDragDropInitialized) {
  window.creativesDragDropInitialized = true;

  console.log('creatives_drag_drop.js loaded');

  const rightZoneRatio = 0.2;
  const draggableClassName = '.creative-tree';
  // Drag and Drop for Creative Tree
  let draggedCreativeId = null;
  let lastDragOverRow = null;

  window.handleDragStart = function(event) {
    const row = event.target.closest(draggableClassName);
    draggedCreativeId = row ? row.id : '';
    event.dataTransfer.effectAllowed = 'move';
    console.log('handleDragStart', draggedCreativeId);
  };

  window.handleDragOver = function(event) {
    event.preventDefault();
    event.dataTransfer.dropEffect = 'move';
    const row = event.target.closest(draggableClassName);
    if (lastDragOverRow && lastDragOverRow !== row) {
      lastDragOverRow.classList.remove(
        'drag-over',
        'drag-over-top',
        'drag-over-bottom',
        'drag-over-child',
        'child-drop-indicator-active'
      );
    }
    if (row) {
      const rect = row.getBoundingClientRect();
      const rightZone = rect.left + rect.width * rightZoneRatio;
      const midpoint = rect.top + rect.height / 2;
      if (event.clientX > rightZone) {
        // Child drop indication
        row.classList.add('drag-over-child', 'child-drop-indicator-active');
        row.classList.remove('drag-over-top', 'drag-over-bottom');
      } else {
        // Up/Down drop indication
        row.classList.remove('drag-over-child', 'child-drop-indicator-active');
        if (event.clientY < midpoint) {
          row.classList.add('drag-over-top');
          row.classList.remove('drag-over-bottom');
        } else {
          row.classList.add('drag-over-bottom');
          row.classList.remove('drag-over-top');
        }
      }
      row.classList.add('drag-over');
      lastDragOverRow = row;
    }
  };

  window.handleDrop = function(event) {
    event.preventDefault();
    const targetRow = event.target.closest(draggableClassName);
    const targetId = targetRow ? targetRow.id : '';
    if (targetRow) {
      targetRow.classList.remove(
        'drag-over',
        'drag-over-top',
        'drag-over-bottom',
        'drag-over-child',
        'child-drop-indicator-active'
      );
    }
    if (lastDragOverRow) {
      lastDragOverRow.classList.remove(
        'drag-over',
        'drag-over-top',
        'drag-over-bottom',
        'drag-over-child',
        'child-drop-indicator-active'
      );
    }
    if (draggedCreativeId && targetId && draggedCreativeId !== targetId) {
      const draggedElem = document.getElementById(draggedCreativeId);
      const draggedChildren = document.getElementById(`creative-children-${draggedCreativeId.replace('creative-', '')}`);
      const targetElem = document.getElementById(targetId);
      const rect = targetElem.getBoundingClientRect();
      const rightZone = rect.left + rect.width * rightZoneRatio;
      const midpoint = rect.top + rect.height / 2;
      let direction = null;
      // Save original position
      const originalParent = draggedElem.parentNode;
      const originalNextSibling = draggedChildren ? draggedChildren.nextSibling : draggedElem.nextSibling;
      if (event.clientX > rightZone) {
        // Append as child
        const targetNum = targetId.replace('creative-', '');
        let childrenContainer = document.getElementById(`creative-children-${targetNum}`);
        if (!childrenContainer) {
          childrenContainer = document.createElement('div');
          childrenContainer.className = 'creative-children';
          childrenContainer.id = `creative-children-${targetNum}`;
          targetElem.parentNode.insertBefore(childrenContainer, targetElem.nextSibling);
        }
        childrenContainer.appendChild(draggedElem);
        if (draggedChildren) childrenContainer.appendChild(draggedChildren);
        direction = 'child';
      } else if (event.clientY < midpoint) {
        // Insert before target
        targetElem.parentNode.insertBefore(draggedElem, targetElem);
        if (draggedChildren) targetElem.parentNode.insertBefore(draggedChildren, targetElem);
        direction = 'up';
      } else {
        // Insert after target
        if (targetElem.nextSibling) {
          targetElem.parentNode.insertBefore(draggedElem, targetElem.nextSibling);
        } else {
          targetElem.parentNode.appendChild(draggedElem);
        }
        if (draggedChildren) {
          if (draggedElem.nextSibling) {
            draggedElem.parentNode.insertBefore(draggedChildren, draggedElem.nextSibling);
          } else {
            draggedElem.parentNode.appendChild(draggedChildren);
          }
        }
        direction = 'down';
      }
      sendNewOrder(
        draggedCreativeId.replace('creative-', ''),
        targetId.replace('creative-', ''),
        direction,
        function revert() {
          if (originalNextSibling) {
            originalParent.insertBefore(draggedElem, originalNextSibling);
            if (draggedChildren) originalParent.insertBefore(draggedChildren, originalNextSibling);
          } else {
            originalParent.appendChild(draggedElem);
            if (draggedChildren) originalParent.appendChild(draggedChildren);
          }
        }
      );
    }
    draggedCreativeId = null;
    lastDragOverRow = null;
  };

  window.handleDragLeave = function(event) {
    const row = event.target.closest(draggableClassName);
    if (row) {
      row.classList.remove(
        'drag-over',
        'drag-over-top',
        'drag-over-bottom',
        'drag-over-child',
        'child-drop-indicator-active'
      );
    }
  };

  function sendNewOrder(draggedId, targetId, direction, onErrorRevert) {
    fetch('/creatives/reorder', {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        'X-CSRF-Token': document.querySelector('meta[name="csrf-token"]').content
      },
      body: JSON.stringify({ dragged_id: draggedId, target_id: targetId, direction: direction })
    })
    .then(response => {
      if (!response.ok) {
        console.error('Failed to update order');
        if (onErrorRevert) onErrorRevert();
      }
    })
    .catch((error) => {
      console.error('Failed to update order', error);
      if (onErrorRevert) onErrorRevert();
    });
  }
}
