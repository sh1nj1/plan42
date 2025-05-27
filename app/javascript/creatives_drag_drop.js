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

  // Global variable to store collapsed states. True means collapsed.
  let userCreativeCollapsedStates = {};

  // Fetch states from server and apply them
  function fetchAndApplyExpansionStates() {
    console.log("Fetching expansion states from server...");
    fetch('/creatives/get_expansion_states', {
      method: 'GET',
      headers: {
        'Accept': 'application/json',
        'X-CSRF-Token': document.querySelector('meta[name="csrf-token"]').content
      }
    })
    .then(response => {
      if (!response.ok) {
        throw new Error('Network response was not ok for get_expansion_states');
      }
      return response.json();
    })
    .then(data => {
      userCreativeCollapsedStates = data || {}; // Ensure it's an object
      console.log("Fetched states:", userCreativeCollapsedStates);
      setupCreativeTogglesEventListenersAndInitialView();
    })
    .catch(error => {
      console.error('Error fetching expansion states:', error);
      // Proceed with setup anyway, possibly with default (expanded) states
      setupCreativeTogglesEventListenersAndInitialView();
    });
  }

  // Setup event listeners for toggles and set initial view based on fetched states
  function setupCreativeTogglesEventListenersAndInitialView() {
    console.log("Setting up creative toggles event listeners and initial view.");
    document.querySelectorAll(".creative-toggle-btn").forEach(function(btn) {
      const creativeId = btn.dataset.creativeId;
      const childrenDiv = document.getElementById(`creative-children-${creativeId}`);

      if (!childrenDiv) return; // No children div, nothing to toggle

      // Set initial view
      if (userCreativeCollapsedStates[creativeId]) { // if true, it's collapsed
        childrenDiv.style.display = "none";
        btn.textContent = "▶";
      } else {
        childrenDiv.style.display = "";
        btn.textContent = "▼";
      }

      // Remove existing event listener to prevent multiple attachments if this function is called again
      // A simple way is to replace the element, but that can be complex.
      // For now, we'll assume this function is called once per element after turbo:load,
      // or that multiple identical listeners don't cause issues.
      // A more robust way: btn.replaceWith(btn.cloneNode(true)); and then re-select the new btn.
      // For simplicity now, we just add. If issues arise, this should be revisited.

      btn.addEventListener("click", function(e) {
        e.preventDefault(); // Prevent any default action
        const isCurrentlyCollapsed = childrenDiv.style.display === "none";
        if (isCurrentlyCollapsed) {
          childrenDiv.style.display = "";
          btn.textContent = "▼";
          delete userCreativeCollapsedStates[creativeId]; // Expanded, so remove from collapsed states
        } else {
          childrenDiv.style.display = "none";
          btn.textContent = "▶";
          userCreativeCollapsedStates[creativeId] = true; // Collapsed, so add to states
        }
        sendExpansionStatesToServer();
      });
    });
  }

  // Send the current state of userCreativeCollapsedStates to the server
  function sendExpansionStatesToServer() {
    console.log("Sending expansion states to server:", userCreativeCollapsedStates);
    fetch('/creatives/set_expansion_states', {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        'X-CSRF-Token': document.querySelector('meta[name="csrf-token"]').content
      },
      body: JSON.stringify({ states: userCreativeCollapsedStates })
    })
    .then(response => {
      if (!response.ok) {
        console.error('Failed to send expansion states to server. Status:', response.status);
        // Optionally, revert the state or notify the user
      } else {
        console.log('Expansion states successfully sent to server.');
      }
    })
    .catch(error => {
      console.error('Error sending expansion states:', error);
      // Optionally, revert the state or notify the user
    });
  }

  document.addEventListener("turbo:load", () => {
    console.log("turbo:load event triggered for creatives_drag_drop.js");
    // Initialize/reset states and fetch fresh from server on each turbo:load
    userCreativeCollapsedStates = {};
    fetchAndApplyExpansionStates();
  });

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
