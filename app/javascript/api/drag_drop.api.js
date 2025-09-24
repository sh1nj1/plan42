function csrfToken() {
  return document.querySelector('meta[name="csrf-token"]')?.content;
}

export function sendNewOrder({ draggedId, targetId, direction }) {
  return fetch('/creatives/reorder', {
    method: 'POST',
    headers: {
      'Content-Type': 'application/json',
      'X-CSRF-Token': csrfToken(),
    },
    body: JSON.stringify({ dragged_id: draggedId, target_id: targetId, direction }),
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
