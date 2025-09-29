function csrfToken() {
  return document.querySelector('meta[name="csrf-token"]')?.content;
}

export function sendNewOrder({ draggedId, draggedIds, targetId, direction }) {
  const payload = { target_id: targetId, direction };
  if (Array.isArray(draggedIds) && draggedIds.length > 0) {
    payload.dragged_ids = draggedIds;
  } else {
    payload.dragged_id = draggedId;
  }

  return fetch('/creatives/reorder', {
    method: 'POST',
    headers: {
      'Content-Type': 'application/json',
      'X-CSRF-Token': csrfToken(),
    },
    body: JSON.stringify(payload),
  });
}

export function sendLinkedCreative({ draggedId, targetId, direction }) {
  return fetch('/creatives/link_drop', {
    method: 'POST',
    headers: {
      'Content-Type': 'application/json',
      'X-CSRF-Token': csrfToken(),
    },
    body: JSON.stringify({ dragged_id: draggedId, target_id: targetId, direction }),
  }).then((response) => {
    if (!response.ok) throw new Error('Failed to create linked creative');
    return response.json();
  });
}
