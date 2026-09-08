/**
 * DOM-independent creative move command.
 *
 * A move is described by `{ ids, targetId, direction, mode }` and nothing else:
 * no rows, no containers, no drag session. That is the whole point — the right
 * creative tree, the left workspace tree, and the keyboard/menu move path all
 * express the same intent, and only the *adapter* that issued it knows how to
 * repaint anything. Adapters own the optimistic DOM; this module owns the
 * server call and the outcome vocabulary.
 *
 * Two server endpoints sit behind one command:
 *
 *   mode 'move' -> POST /creatives/reorder    (Reorderer#reorder / #reorder_multiple)
 *   mode 'link' -> POST /creatives/link_drop  (Reorderer#link_drop)
 *
 * ## Partial success policy
 *
 * `move` is atomic. `reorder_multiple` authorises and validates every id before
 * it mutates a row, so the batch either lands whole or not at all — the result
 * is `success` or `failure`, never `partial`.
 *
 * `link` is not atomic and cannot be made atomic from the client: there is no
 * batch link endpoint, so N selected creatives mean N independent inserts. The
 * policy this module implements, deliberately:
 *
 *   1. Every id is attempted. One failure does not cancel the ids behind it —
 *      a link shell is an additive, non-destructive insert, so a permission
 *      failure on one creative says nothing about the next.
 *   2. Shells that were already created are NOT rolled back. Undoing them would
 *      need destroy calls that can fail in turn, leaving a worse mess than the
 *      partial state. `rolledBack` is therefore always false, and is reported
 *      explicitly so callers do not have to assume.
 *   3. `partial` is a distinct status. Callers must not treat it as success
 *      (some links are missing) nor as failure (some links exist, and a blanket
 *      "failed" message would send the user to create duplicates).
 *   4. Requests run one at a time. Each link_drop resequences the destination's
 *      sibling list, so concurrent inserts race and produce a scrambled order.
 *   5. For direction 'down' the requests are issued in reverse selection order,
 *      because every insert lands directly after the target — sending 3,4,5
 *      forwards would leave them ordered 5,4,3. `succeededIds` and `payloads`
 *      are still reported in selection order, so callers never see the reversal.
 *
 * ## Expired sessions
 *
 * `Authentication#request_authentication` redirects *any* request without a
 * live session to the login page, POSTs included, and fetch follows that
 * redirect and returns an `ok` HTML response. A redirected response is
 * therefore reported as `authentication_required`, never as a move that
 * landed — otherwise the adapter would keep an optimistic DOM the database
 * disagrees with until the next reload.
 *
 * `executeMoveCommand` resolves for every transport and server outcome. The
 * only rejection path is an invalid command, which is a programming error.
 */

import { sendNewOrder, sendLinkedCreative, isAuthenticationRedirect } from '../../lib/api/drag_drop';

export const MOVE_MODES = Object.freeze({
  MOVE: 'move',
  LINK: 'link',
});

export const MOVE_DIRECTIONS = Object.freeze(['up', 'down', 'child']);

export const MOVE_STATUSES = Object.freeze({
  SUCCESS: 'success',
  PARTIAL: 'partial',
  FAILURE: 'failure',
});

export const MOVE_FAILURE_REASONS = Object.freeze({
  AUTHENTICATION_REQUIRED: 'authentication_required',
  PERMISSION_DENIED: 'permission_denied',
  REJECTED: 'rejected',
  SERVER_ERROR: 'server_error',
  NETWORK_ERROR: 'network_error',
});

/** Thrown by {@link createMoveCommand} when the command cannot describe a move. */
export class InvalidMoveCommandError extends Error {
  constructor(reason) {
    super(`Invalid move command: ${reason}`);
    this.name = 'InvalidMoveCommandError';
    this.reason = reason;
  }
}

function normalizeId(value) {
  if (value === null || value === undefined) return '';
  return String(value).trim();
}

function normalizeIds(value) {
  const list = Array.isArray(value) ? value : [value];
  const seen = new Set();
  const ids = [];

  list.forEach((entry) => {
    const id = normalizeId(entry);
    if (!id || seen.has(id)) return;
    seen.add(id);
    ids.push(id);
  });

  return ids;
}

/**
 * Validate and normalise a move intent.
 *
 * @param {{ids: (string|number|Array), targetId: string|number, direction: string, mode?: string}} intent
 * @returns {Readonly<{ids: string[], targetId: string, direction: string, mode: string}>}
 * @throws {InvalidMoveCommandError}
 */
export function createMoveCommand({ ids, targetId, direction, mode = MOVE_MODES.MOVE } = {}) {
  const normalizedIds = normalizeIds(ids);
  if (normalizedIds.length === 0) throw new InvalidMoveCommandError('empty_ids');

  const normalizedTargetId = normalizeId(targetId);
  if (!normalizedTargetId) throw new InvalidMoveCommandError('missing_target');

  if (!MOVE_DIRECTIONS.includes(direction)) throw new InvalidMoveCommandError('invalid_direction');
  if (!Object.values(MOVE_MODES).includes(mode)) throw new InvalidMoveCommandError('invalid_mode');

  // The server rejects this too, but catching it here keeps an adapter from
  // optimistically moving a row onto itself and then having to undo it.
  if (normalizedIds.includes(normalizedTargetId)) {
    throw new InvalidMoveCommandError('target_in_selection');
  }

  return Object.freeze({
    ids: Object.freeze(normalizedIds),
    targetId: normalizedTargetId,
    direction,
    mode,
  });
}

function classifyStatus(status) {
  // 401 is "sign in again", 403 is "you may not do that" — different messages,
  // so they get different reasons.
  if (status === 401) return MOVE_FAILURE_REASONS.AUTHENTICATION_REQUIRED;
  if (status === 403) return MOVE_FAILURE_REASONS.PERMISSION_DENIED;
  if (typeof status !== 'number') return MOVE_FAILURE_REASONS.NETWORK_ERROR;
  if (status >= 500) return MOVE_FAILURE_REASONS.SERVER_ERROR;
  return MOVE_FAILURE_REASONS.REJECTED;
}

function failureFromError(id, error) {
  const status = typeof error?.status === 'number' ? error.status : null;
  return {
    id,
    status,
    reason: error?.authenticationRequired
      ? MOVE_FAILURE_REASONS.AUTHENTICATION_REQUIRED
      : classifyStatus(status),
    message: error?.message || '',
  };
}

function buildResult(command, { succeeded, failures, payloads = [] }) {
  const failedIds = new Set(failures.map((failure) => failure.id));
  const succeededIds = command.ids.filter((id) => succeeded.has(id));
  let status = MOVE_STATUSES.FAILURE;
  if (failedIds.size === 0) {
    status = MOVE_STATUSES.SUCCESS;
  } else if (succeededIds.length > 0) {
    status = MOVE_STATUSES.PARTIAL;
  }

  return {
    command,
    status,
    ok: status === MOVE_STATUSES.SUCCESS,
    succeededIds,
    failedIds: command.ids.filter((id) => failedIds.has(id)),
    failures,
    payloads,
    // Always false: see the partial success policy at the top of this file.
    rolledBack: false,
  };
}

async function executeReorder(command, api) {
  const { ids, targetId, direction } = command;
  const payload = ids.length > 1
    ? { draggedIds: [...ids], targetId, direction }
    : { draggedId: ids[0], targetId, direction };

  let response;
  try {
    response = await api.sendNewOrder(payload);
  } catch (error) {
    return buildResult(command, {
      succeeded: new Set(),
      failures: ids.map((id) => failureFromError(id, error)),
    });
  }

  // An expired session redirects the POST to the login page and fetch follows
  // it, so a redirected response is `ok` without the reorder ever running.
  const unauthenticated = isAuthenticationRedirect(response);

  if (response && response.ok && !unauthenticated) {
    return buildResult(command, { succeeded: new Set(ids), failures: [] });
  }

  const status = typeof response?.status === 'number' ? response.status : null;
  return buildResult(command, {
    succeeded: new Set(),
    failures: ids.map((id) => ({
      id,
      status,
      reason: unauthenticated
        ? MOVE_FAILURE_REASONS.AUTHENTICATION_REQUIRED
        : classifyStatus(status),
      message: '',
    })),
  });
}

async function executeLinkDrop(command, api) {
  const { ids, targetId, direction } = command;
  // See policy note 5: "down" inserts each shell immediately after the target.
  const requestOrder = direction === 'down' ? [...ids].reverse() : [...ids];

  const succeeded = new Set();
  const failures = [];
  const dataById = new Map();

  // Sequential on purpose (policy note 4) — link_drop resequences siblings.
  for (const id of requestOrder) {
    try {
      // eslint-disable-next-line no-await-in-loop
      const data = await api.sendLinkedCreative({ draggedId: id, targetId, direction });
      succeeded.add(id);
      dataById.set(id, data);
    } catch (error) {
      failures.push(failureFromError(id, error));
    }
  }

  return buildResult(command, {
    succeeded,
    // Report in selection order regardless of the order the requests went out.
    failures: ids.map((id) => failures.find((failure) => failure.id === id)).filter(Boolean),
    payloads: ids
      .filter((id) => succeeded.has(id))
      .map((id) => ({ id, data: dataById.get(id) })),
  });
}

/**
 * Run a move command against the server.
 *
 * Never rejects for a transport or server failure — inspect `result.status`.
 *
 * @param {object} command a command from {@link createMoveCommand}, or a plain
 *   intent object which is normalised the same way.
 * @param {{api?: {sendNewOrder?: Function, sendLinkedCreative?: Function}}} [options]
 * @returns {Promise<object>} move result
 * @throws {InvalidMoveCommandError} when the command cannot describe a move
 */
export async function executeMoveCommand(command, { api = {} } = {}) {
  const normalized = createMoveCommand(command);
  const resolvedApi = {
    sendNewOrder: api.sendNewOrder || sendNewOrder,
    sendLinkedCreative: api.sendLinkedCreative || sendLinkedCreative,
  };

  return normalized.mode === MOVE_MODES.LINK
    ? executeLinkDrop(normalized, resolvedApi)
    : executeReorder(normalized, resolvedApi);
}
