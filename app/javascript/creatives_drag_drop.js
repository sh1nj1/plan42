if (!window.creativesDragDropInitialized) {
  window.creativesDragDropInitialized = true;

  const childZoneRatio = 0.3;
  const coordPrecision = 5;
  const draggableClassName = '.creative-tree';
  // Drag and Drop for Creative Tree
  let draggedCreativeId = null;
  let lastDragOverRow = null;

  function relaxedCoord(value) {
    return Math.round(value / coordPrecision) * coordPrecision;
  }

  window.handleDragStart = function(event) {
    const row = event.target.closest(draggableClassName);
    if (!row || row.draggable === false) return;
    draggedCreativeId = row.id;
    event.dataTransfer.effectAllowed = 'move';
  };

  window.handleDragOver = function(event) {
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
    if (!row || row.draggable === false) return;
    event.preventDefault();
    event.dataTransfer.dropEffect = 'move';
    if (row) {
      const rect = row.getBoundingClientRect();
      const topZone = relaxedCoord(rect.top + rect.height * childZoneRatio);
      const bottomZone = relaxedCoord(rect.bottom - rect.height * childZoneRatio);
      const y = relaxedCoord(event.clientY);
      if (y < topZone) {
        // Insert before target
        row.classList.add('drag-over-top');
        row.classList.remove('drag-over-bottom', 'drag-over-child', 'child-drop-indicator-active');
        const childIndicator = row.querySelector('.child-drop-indicator');
        if (childIndicator) childIndicator.remove();
      } else if (y > bottomZone) {
        // Insert after target
        row.classList.add('drag-over-bottom');
        row.classList.remove('drag-over-top', 'drag-over-child', 'child-drop-indicator-active');
        const childIndicator = row.querySelector('.child-drop-indicator');
        if (childIndicator) childIndicator.remove();
      } else {
          // Child drop indication
          row.classList.add('drag-over-child', 'child-drop-indicator-active');
          row.classList.remove('drag-over-top', 'drag-over-bottom');
      }
        row.classList.add('drag-over');
      lastDragOverRow = row;
    }
  };

  window.handleDrop = function(event) {
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
    if (!targetRow || targetRow.draggable === false) {
      draggedCreativeId = null;
      lastDragOverRow = null;
      return;
    }
    event.preventDefault();
    if (draggedCreativeId && targetId && draggedCreativeId !== targetId) {
      const draggedElem = document.getElementById(draggedCreativeId);
      const draggedChildren = document.getElementById(`creative-children-${draggedCreativeId.replace('creative-', '')}`);
      const targetElem = document.getElementById(targetId);
      const rect = targetElem.getBoundingClientRect();
      const topZone = relaxedCoord(rect.top + rect.height * childZoneRatio);
      const bottomZone = relaxedCoord(rect.bottom - rect.height * childZoneRatio);
      const y = relaxedCoord(event.clientY);
      let direction = null;
      // Save original position
      const originalParent = draggedElem.parentNode;
      const originalNextSibling = draggedChildren ? draggedChildren.nextSibling : draggedElem.nextSibling;
      if (y >= topZone && y <= bottomZone) {
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
      } else if (y < topZone) {
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
    if (!row || row.draggable === false) return;
    row.classList.remove(
      'drag-over',
      'drag-over-top',
      'drag-over-bottom',
      'drag-over-child',
      'child-drop-indicator-active'
    );
  };

  function sendNewOrder(draggedId, targetId, direction, onErrorRevert) {
    fetch('/creatives/reorder', {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        'X-CSRF-Token': document.querySelector('meta[name="csrf-token"]')?.content
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
