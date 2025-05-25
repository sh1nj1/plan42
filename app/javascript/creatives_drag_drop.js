if (!window.creativesDragDropInitialized) {
  window.creativesDragDropInitialized = true;

  console.log('creatives_drag_drop.js loaded');

  const rightZoneRatio = 0.1; // 10% of the width for child drop indication
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
      const rightZone = rect.left + rect.width * rightZoneRatio;
      const midpoint = rect.top + rect.height / 2;
      if (event.clientX > rightZone) {
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
      } else {
        // Up/Down drop indication
        row.classList.remove('drag-over-child');
        const childIndicator = row.querySelector('.child-drop-indicator');
        if (childIndicator) childIndicator.remove();
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
    if (targetRow) targetRow.classList.remove('drag-over', 'drag-over-top', 'drag-over-bottom', 'drag-over-child');
    if (lastDragOverRow) lastDragOverRow.classList.remove('drag-over', 'drag-over-top', 'drag-over-bottom', 'drag-over-child');
    const childIndicator = targetRow ? targetRow.querySelector('.child-drop-indicator') : null;
    if (childIndicator) childIndicator.remove();
    if (draggedCreativeId && targetId && draggedCreativeId !== targetId) {
      const draggedElem = document.getElementById(draggedCreativeId);
      const targetElem = document.getElementById(targetId);
      const rect = targetElem.getBoundingClientRect();
      const rightZone = rect.left + rect.width * rightZoneRatio;
      const midpoint = rect.top + rect.height / 2;
      let direction = null;
      let asChild = false;
      // Save original position
      const originalNextSibling = draggedElem.nextSibling;
      const originalParent = draggedElem.parentNode;
      if (event.clientX > rightZone) {
        // Append as child
        let childrenContainer = targetElem.querySelector('.creative-children');
        if (!childrenContainer) {
          childrenContainer = document.createElement('div');
          childrenContainer.className = 'creative-children';
          targetElem.appendChild(childrenContainer);
        }
        childrenContainer.appendChild(draggedElem);
        direction = 'child';
      } else if (event.clientY < midpoint) {
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
    if (row) {
      row.classList.remove('drag-over', 'drag-over-top', 'drag-over-bottom', 'drag-over-child');
      const childIndicator = row.querySelector('.child-drop-indicator');
      if (childIndicator) childIndicator.remove();
    }
  };

  // Toggle children visibility on ▶/▼ button click
  function setupCreativeToggles() {
    console.log("Setting up creative toggles");
    // Get current creative id from path, e.g. /creatives/10 or /creatives
    let match = window.location.pathname.match(/\/creatives\/(\d+)/);
    const currentCreativeId = match ? match[1] : 'root';
    document.querySelectorAll(".creative-toggle-btn").forEach(function(btn) {
      btn.addEventListener("click", function(e) {
        const creativeId = btn.dataset.creativeId;
        const childrenDiv = document.getElementById(`creative-children-${creativeId}`);
        if (childrenDiv) {
          const isHidden = childrenDiv.style.display === "none";
          childrenDiv.style.display = isHidden ? "" : "none";
          btn.textContent = isHidden ? "▼" : "▶";
          // Store expansion state in localStorage, scoped by currentCreativeId
          let allStates = JSON.parse(localStorage.getItem("creativeTreeExpandedByParent") || '{}');
          let expanded = allStates[currentCreativeId] || {};
          if (isHidden) {
            delete expanded[creativeId];
          } else {
            expanded[creativeId] = false;
          }
          allStates[currentCreativeId] = expanded;
          localStorage.setItem("creativeTreeExpandedByParent", JSON.stringify(allStates));
        }
      });

      // On load, restore state
      const creativeId = btn.dataset.creativeId;
      const childrenDiv = document.getElementById(`creative-children-${creativeId}`);
      let allStates = JSON.parse(localStorage.getItem("creativeTreeExpandedByParent") || '{}');
      let expanded = allStates[currentCreativeId] || {};
      if (childrenDiv && expanded[creativeId] === undefined) {
        childrenDiv.style.display = "";
        btn.textContent = "▼";
      } else if (childrenDiv) {
        childrenDiv.style.display = "none";
        btn.textContent = "▶";
      }
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
