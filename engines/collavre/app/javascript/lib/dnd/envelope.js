import {
  ensureDragSessionToken,
  ensureDragWindowId,
  readDragSessionToken,
} from './session';

export const LEGACY_MIME_TYPES = Object.freeze({
  creative: 'application/x-collavre-creative',
  topic: 'application/x-topic-move',
  context: 'application/x-context-id',
  comments: 'application/x-comment-ids',
  agent: 'application/x-agent-drop',
});

const TOPIC_ID_MIME_TYPE = 'application/x-topic-id';
const SUPPORTED_KINDS = Object.keys(LEGACY_MIME_TYPES);

function transferTypes(dataTransfer) {
  if (!dataTransfer?.types) return new Set();
  return new Set(Array.from(dataTransfer.types));
}

export function getDragKind(dataTransfer) {
  const types = transferTypes(dataTransfer);
  return SUPPORTED_KINDS.find((kind) => {
    if (types.has(LEGACY_MIME_TYPES[kind])) return true;
    return kind === 'topic' && types.has(TOPIC_ID_MIME_TYPE);
  }) || null;
}

function normalizedIds(ids) {
  if (!Array.isArray(ids)) return null;

  const values = ids
    .filter((id) => id !== null && id !== undefined && String(id) !== '')
    .map(String);
  const unique = [...new Set(values)];
  return unique.length > 0 ? unique : null;
}

function isPayload(value) {
  return !!value && typeof value === 'object' && !Array.isArray(value);
}

function safeParse(data) {
  if (!data) return null;
  try {
    return JSON.parse(data);
  } catch (error) {
    console.error('Failed to parse drag data', error);
    return null;
  }
}

function readTransferData(dataTransfer, type) {
  if (!dataTransfer || typeof dataTransfer.getData !== 'function') return '';
  try {
    return dataTransfer.getData(type) || '';
  } catch (error) {
    console.error(`Failed to read drag data for ${type}`, error);
    return '';
  }
}

function probeLegacyKind(dataTransfer) {
  const declaredKind = getDragKind(dataTransfer);
  if (declaredKind) return declaredKind;

  return SUPPORTED_KINDS.find((kind) =>
    !!readTransferData(dataTransfer, LEGACY_MIME_TYPES[kind])) ||
    (readTransferData(dataTransfer, TOPIC_ID_MIME_TYPE) ? 'topic' : null);
}

function readCreative(dataTransfer) {
  const parsed = safeParse(readTransferData(dataTransfer, LEGACY_MIME_TYPES.creative));
  if (!isPayload(parsed) || !parsed.creativeId || !parsed.treeId) return null;

  const expectedToken = readDragSessionToken();
  if (!expectedToken || parsed.token !== expectedToken) return null;

  const ids = normalizedIds([
    ...(Array.isArray(parsed.selectedCreativeIds) ? parsed.selectedCreativeIds : []),
    parsed.creativeId,
  ]);
  if (!ids) return null;

  const { token: _token, ...payload } = parsed;
  return { kind: 'creative', ids, payload };
}

function readTopic(dataTransfer) {
  const moveData = readTransferData(dataTransfer, LEGACY_MIME_TYPES.topic);
  if (moveData) {
    const parsed = safeParse(moveData);
    if (!isPayload(parsed) || !parsed.topicId) return null;
    const ids = normalizedIds([parsed.topicId]);
    const { topicId: _topicId, ...payload } = parsed;
    return ids ? { kind: 'topic', ids, payload } : null;
  }

  const ids = normalizedIds([readTransferData(dataTransfer, TOPIC_ID_MIME_TYPE)]);
  return ids ? { kind: 'topic', ids, payload: {} } : null;
}

function readContext(dataTransfer) {
  const ids = normalizedIds([
    readTransferData(dataTransfer, LEGACY_MIME_TYPES.context),
  ]);
  return ids ? { kind: 'context', ids, payload: {} } : null;
}

function readComments(dataTransfer) {
  const ids = normalizedIds(
    safeParse(readTransferData(dataTransfer, LEGACY_MIME_TYPES.comments))
  );
  return ids ? { kind: 'comments', ids, payload: {} } : null;
}

function readAgent(dataTransfer) {
  const parsed = safeParse(readTransferData(dataTransfer, LEGACY_MIME_TYPES.agent));
  if (!isPayload(parsed) || !parsed.id) return null;
  const ids = normalizedIds([parsed.id]);
  const { id: _id, ...payload } = parsed;
  return ids ? { kind: 'agent', ids, payload } : null;
}

const LEGACY_READERS = {
  creative: readCreative,
  topic: readTopic,
  context: readContext,
  comments: readComments,
  agent: readAgent,
};

export function readDragData(dataTransfer) {
  const legacyKind = probeLegacyKind(dataTransfer);
  return legacyKind ? LEGACY_READERS[legacyKind](dataTransfer) : null;
}

function writeLegacyData(dataTransfer, data, token, sourceWindowId) {
  const { kind, ids, payload } = data;

  if (kind === 'creative') {
    const creativeId = payload.creativeId || ids[0];
    const legacyPayload = JSON.stringify({
      ...payload,
      creativeId,
      selectedCreativeIds: ids,
      token,
      sourceWindowId,
    });
    dataTransfer.setData(LEGACY_MIME_TYPES.creative, legacyPayload);
    dataTransfer.setData('text/plain', legacyPayload);
  } else if (kind === 'topic') {
    dataTransfer.setData(TOPIC_ID_MIME_TYPE, ids[0]);
    dataTransfer.setData(LEGACY_MIME_TYPES.topic, JSON.stringify({
      ...payload,
      topicId: ids[0],
    }));
  } else if (kind === 'context') {
    dataTransfer.setData(LEGACY_MIME_TYPES.context, ids[0]);
  } else if (kind === 'comments') {
    dataTransfer.setData(LEGACY_MIME_TYPES.comments, JSON.stringify(ids));
  } else if (kind === 'agent') {
    dataTransfer.setData(LEGACY_MIME_TYPES.agent, JSON.stringify({
      ...payload,
      id: ids[0],
    }));
  }
}

export function writeDragData(dataTransfer, data) {
  if (!dataTransfer || typeof dataTransfer.setData !== 'function') return false;
  if (!isPayload(data) || !SUPPORTED_KINDS.includes(data.kind)) return false;
  if (!isPayload(data.payload)) return false;

  const ids = normalizedIds(data.ids);
  if (!ids) return false;

  const token = data.kind === 'creative' ? ensureDragSessionToken() : null;
  if (data.kind === 'creative' && !token) return false;

  const payload = data.payload;
  const sourceWindowId = data.kind === 'creative'
    ? payload.sourceWindowId || ensureDragWindowId()
    : payload.sourceWindowId || null;
  const normalized = { kind: data.kind, ids, payload };

  writeLegacyData(dataTransfer, normalized, token, sourceWindowId);
  return true;
}
