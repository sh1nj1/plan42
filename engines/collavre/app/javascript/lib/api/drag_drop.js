import csrfFetch from './csrf_fetch';
import { apiErrorFromResponse } from './api_error';

export function sendNewOrder({ draggedId, draggedIds, targetId, direction }) {
  const payload = { target_id: targetId, direction };
  if (Array.isArray(draggedIds) && draggedIds.length > 0) {
    payload.dragged_ids = draggedIds;
  } else {
    payload.dragged_id = draggedId;
  }

  return csrfFetch('/creatives/reorder', {
    method: 'POST',
    headers: {
      'Content-Type': 'application/json',
    },
    body: JSON.stringify(payload),
  });
}

export function sendTopicMove({ topicId, sourceCreativeId, targetCreativeId }) {
  return csrfFetch(`/creatives/${sourceCreativeId}/topics/${topicId}/move`, {
    method: 'PATCH',
    headers: {
      'Content-Type': 'application/json',
    },
    body: JSON.stringify({ target_creative_id: targetCreativeId }),
  }).then((response) => {
    if (!response.ok) {
      return response.json().then((data) => {
        throw new Error(data.error || 'Failed to move topic');
      });
    }
    return response.json();
  });
}

export function sendLinkedCreative({ draggedId, targetId, direction }) {
  return csrfFetch('/creatives/link_drop', {
    method: 'POST',
    headers: {
      'Content-Type': 'application/json',
    },
    body: JSON.stringify({ dragged_id: draggedId, target_id: targetId, direction }),
  }).then((response) => {
    // An ApiError keeps the HTTP status attached: link_drop answers 403 for a
    // permission failure and 422 for a domain rejection, and a multi-link drop
    // has to report which of the two happened per creative.
    if (!response.ok) return apiErrorFromResponse(response).then((error) => { throw error; });
    return response.json();
  });
}
