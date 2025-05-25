if (!window.creativesDragDropInitialized) {
  window.creativesDragDropInitialized = true;

  console.log('creatives_drag_drop.js loaded');

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
      lastDragOverRow.classList.remove('drag-over', 'drag-over-top', 'drag-over-bottom');
    }
    if (row) {
      // Determine direction
      const rect = row.getBoundingClientRect();
      const midpoint = rect.top + rect.height / 2;
      if (event.clientY < midpoint) {
        row.classList.add('drag-over-top');
        row.classList.remove('drag-over-bottom');
      } else {
        row.classList.add('drag-over-bottom');
        row.classList.remove('drag-over-top');
      }
      row.classList.add('drag-over');
      lastDragOverRow = row;
    }
    // console.log('handleDragOver', row ? row.id : '');
  };

  window.handleDrop = function(event) {
    event.preventDefault();
    const targetRow = event.target.closest(draggableClassName);
    const targetId = targetRow ? targetRow.id : '';
    if (targetRow) targetRow.classList.remove('drag-over', 'drag-over-top', 'drag-over-bottom');
    if (lastDragOverRow) lastDragOverRow.classList.remove('drag-over', 'drag-over-top', 'drag-over-bottom');
    console.log('handleDrop', { draggedCreativeId, targetId });
    if (draggedCreativeId && targetId && draggedCreativeId !== targetId) {
      const draggedElem = document.getElementById(draggedCreativeId);
      const targetElem = document.getElementById(targetId);
      const rect = targetElem.getBoundingClientRect();
      const midpoint = rect.top + rect.height / 2;
      let direction;
      // Save original position
      const originalNextSibling = draggedElem.nextSibling;
      const originalParent = draggedElem.parentNode;
      if (event.clientY < midpoint) {
        // Insert before target
        targetElem.parentNode.insertBefore(draggedElem, targetElem);
        direction = 'up';
      } else {
        // Insert after target
        if (targetElem.nextSibling) {
          targetElem.parentNode.insertBefore(draggedElem, targetElem.nextSibling);
        } else {
          targetElem.parentNode.appendChild(draggedElem);
        }
        direction = 'down';
      }
      sendNewOrder(
        draggedCreativeId.replace('creative-', ''),
        targetId.replace('creative-', ''),
        direction,
        // revert callback
        function revert() {
          if (originalNextSibling) {
            originalParent.insertBefore(draggedElem, originalNextSibling);
          } else {
            originalParent.appendChild(draggedElem);
          }
        }
      );
    }
    draggedCreativeId = null;
    lastDragOverRow = null;
  };

  window.handleDragLeave = function(event) {
    const row = event.target.closest(draggableClassName);
    if (row) row.classList.remove('drag-over', 'drag-over-top', 'drag-over-bottom');
  };

  // Toggle children visibility on ▶/▼ button click
  function setupCreativeToggles() {
    console.log("Setting up creative toggles");
    document.querySelectorAll(".creative-toggle-btn").forEach(function(btn) {
      btn.addEventListener("click", function(e) {
        const creativeId = btn.dataset.creativeId;
        const childrenDiv = document.getElementById(`creative-children-${creativeId}`);
        if (childrenDiv) {
          const isHidden = childrenDiv.style.display === "none";
          childrenDiv.style.display = isHidden ? "" : "none";
          btn.textContent = isHidden ? "▼" : "▶";
        }
      });
    });
  }

  // XXX: do not initialize Toggles it only do once when page loads or changes, so only use turbo:load
  // document.addEventListener("DOMContentLoaded", setupCreativeToggles);
  document.addEventListener("turbo:load", setupCreativeToggles);

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
