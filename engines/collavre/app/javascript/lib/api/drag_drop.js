import csrfFetch from './csrf_fetch';
import { ApiError, apiErrorFromResponse } from './api_error';

/**
 * True when the response is the login page rather than the endpoint's answer.
 *
 * `Authentication#request_authentication` redirects *every* request without a
 * live session to `new_session_path` — POSTs included — and fetch follows that
 * redirect and returns a perfectly `ok` HTML page. Trusting `response.ok`
 * alone would read an expired session as a successful move.
 *
 * @param {Response} response
 * @returns {boolean}
 */
export function isAuthenticationRedirect(response) {
  return response?.redirected === true;
}

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
    if (isAuthenticationRedirect(response)) {
      const error = new ApiError('Authentication required', { status: response.status });
      error.authenticationRequired = true;
      throw error;
    }
    // An ApiError keeps the HTTP status attached: link_drop answers 403 for a
    // permission failure and 422 for a domain rejection, and a multi-link drop
    // has to report which of the two happened per creative.
    if (!response.ok) return apiErrorFromResponse(response).then((error) => { throw error; });
    return response.json();
  });
}
