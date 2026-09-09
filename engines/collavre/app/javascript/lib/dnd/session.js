export const DRAG_TOKEN_STORAGE_KEY = 'collavre.dragToken';
export const DROP_SIGNAL_STORAGE_KEY = 'collavre.dragDropSignal';
export const WINDOW_ID_SESSION_KEY = 'collavre.dragWindowId';
export const DROP_COMPLETED_EVENT = 'collavre:creative-drop-complete';

let cachedDragToken;
let cachedWindowId;

function generateRandomIdentifier(context) {
  const fallback = () =>
    `${Date.now().toString(36)}-${Math.random().toString(36).slice(2)}`;

  try {
    const { crypto } = window;
    if (crypto && typeof crypto.randomUUID === 'function') {
      return crypto.randomUUID();
    }
  } catch (error) {
    console.error(`Failed to access crypto API for ${context}`, error);
  }

  return fallback();
}

export function readDragSessionToken() {
  if (cachedDragToken) return cachedDragToken;
  if (typeof window === 'undefined') return null;

  try {
    const storedToken = window.localStorage?.getItem(DRAG_TOKEN_STORAGE_KEY);
    if (storedToken) cachedDragToken = storedToken;
    return cachedDragToken || null;
  } catch (error) {
    console.error('Failed to read drag session token from storage', error);
    return null;
  }
}

export function ensureDragSessionToken() {
  if (typeof window === 'undefined') return null;

  const existing = readDragSessionToken();
  if (existing) return existing;

  try {
    const storage = window.localStorage;
    if (!storage) return null;

    const token = generateRandomIdentifier('drag token generation');
    storage.setItem(DRAG_TOKEN_STORAGE_KEY, token);
    cachedDragToken = token;
    return token;
  } catch (error) {
    console.error('Failed to persist drag session token', error);
    return null;
  }
}

export function readDragWindowId() {
  if (cachedWindowId) return cachedWindowId;
  if (typeof window === 'undefined') return null;

  try {
    const storedId = window.sessionStorage?.getItem(WINDOW_ID_SESSION_KEY);
    if (storedId) cachedWindowId = storedId;
    return cachedWindowId || null;
  } catch (error) {
    console.error('Failed to read drag window id from session storage', error);
    return cachedWindowId || null;
  }
}

export function ensureDragWindowId() {
  if (typeof window === 'undefined') return null;

  const existing = readDragWindowId();
  if (existing) return existing;

  const id = generateRandomIdentifier('drag window id generation');
  try {
    window.sessionStorage?.setItem(WINDOW_ID_SESSION_KEY, id);
  } catch (error) {
    console.error('Failed to persist drag window id', error);
  }
  cachedWindowId = id;
  return id;
}

export function emitDropSignal(detail) {
  if (typeof window === 'undefined') return false;

  const sessionToken = readDragSessionToken();
  if (!sessionToken) return false;

  try {
    const storage = window.localStorage;
    if (!storage) return false;

    const payload = JSON.stringify({
      ...detail,
      sessionToken,
      nonce: generateRandomIdentifier('drag drop signal'),
    });
    storage.setItem(DROP_SIGNAL_STORAGE_KEY, payload);
    storage.removeItem(DROP_SIGNAL_STORAGE_KEY);
    return true;
  } catch (error) {
    console.error('Failed to broadcast drop completion signal', error);
    return false;
  }
}

export function readDropSignal(event) {
  if (!event || event.key !== DROP_SIGNAL_STORAGE_KEY || !event.newValue) {
    return null;
  }

  let payload;
  try {
    payload = JSON.parse(event.newValue);
  } catch (error) {
    console.error('Failed to parse drop completion payload', error);
    return null;
  }

  if (!payload || typeof payload !== 'object') return null;

  const sessionToken = readDragSessionToken();
  if (!sessionToken || payload.sessionToken !== sessionToken) return null;

  const windowId = readDragWindowId();
  if (!windowId || payload.sourceWindowId !== windowId) return null;

  return payload;
}

export function dispatchDropCompletion(detail) {
  if (typeof window === 'undefined') return false;

  try {
    window.dispatchEvent(new window.CustomEvent(DROP_COMPLETED_EVENT, { detail }));
    return true;
  } catch (error) {
    console.error('Failed to dispatch creative drop completion event', error);
    return false;
  }
}

export function resetDragSessionCache() {
  cachedDragToken = undefined;
  cachedWindowId = undefined;
}
