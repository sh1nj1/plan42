if (!window.creativesDragDropInitialized) {
  window.creativesDragDropInitialized = true;

  console.log('creatives_drag_drop.js loaded');

  const childZoneRatio = 0.3;
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
      lastDragOverRow.classList.remove('drag-over', 'drag-over-top', 'drag-over-bottom', 'drag-over-child');
      const childIndicator = lastDragOverRow.querySelector('.child-drop-indicator');
      if (childIndicator) childIndicator.remove();
    }
    if (row) {
      const rect = row.getBoundingClientRect();
      const topZone = rect.top + rect.height * childZoneRatio;
      const bottomZone = rect.bottom - rect.height * childZoneRatio;
      if (event.clientY < topZone) {
        // Insert before target
        row.classList.add('drag-over-top');
        row.classList.remove('drag-over-bottom', 'drag-over-child');
        const childIndicator = row.querySelector('.child-drop-indicator');
        if (childIndicator) childIndicator.remove();
      } else if (event.clientY > bottomZone) {
        // Insert after target
        row.classList.add('drag-over-bottom');
        row.classList.remove('drag-over-top', 'drag-over-child');
        const childIndicator = row.querySelector('.child-drop-indicator');
        if (childIndicator) childIndicator.remove();
      } else {
        // Child drop indication
        row.classList.add('drag-over-child');
        row.classList.remove('drag-over-top', 'drag-over-bottom');
        if (!row.querySelector('.child-drop-indicator')) {
          const indicator = document.createElement('span');
          indicator.className = 'child-drop-indicator';
          indicator.innerHTML = '↳';
          indicator.style.marginLeft = '12px';
          indicator.style.color = '#2196f3';
          indicator.style.fontSize = '1.3em';
          row.appendChild(indicator);
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
    if (targetRow) targetRow.classList.remove('drag-over', 'drag-over-top', 'drag-over-bottom', 'drag-over-child');
    if (lastDragOverRow) lastDragOverRow.classList.remove('drag-over', 'drag-over-top', 'drag-over-bottom', 'drag-over-child');
    const childIndicator = targetRow ? targetRow.querySelector('.child-drop-indicator') : null;
    if (childIndicator) childIndicator.remove();
    if (draggedCreativeId && targetId && draggedCreativeId !== targetId) {
      const draggedElem = document.getElementById(draggedCreativeId);
      const draggedChildren = document.getElementById(`creative-children-${draggedCreativeId.replace('creative-', '')}`);
      const targetElem = document.getElementById(targetId);
      const rect = targetElem.getBoundingClientRect();
      const topZone = rect.top + rect.height * childZoneRatio;
      const bottomZone = rect.bottom - rect.height * childZoneRatio;
      let direction = null;
      // Save original position
      const originalParent = draggedElem.parentNode;
      const originalNextSibling = draggedChildren ? draggedChildren.nextSibling : draggedElem.nextSibling;
      if (event.clientY >= topZone && event.clientY <= bottomZone) {
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
      } else if (event.clientY < topZone) {
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
      row.classList.remove('drag-over', 'drag-over-top', 'drag-over-bottom', 'drag-over-child');
      const childIndicator = row.querySelector('.child-drop-indicator');
      if (childIndicator) childIndicator.remove();
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
