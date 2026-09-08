import { jest } from '@jest/globals';
import {
  DND_MIME_TYPE,
  LEGACY_MIME_TYPES,
  getDragKind,
  readDragData,
  writeDragData,
} from '../envelope';
import {
  DRAG_TOKEN_STORAGE_KEY,
  WINDOW_ID_SESSION_KEY,
  resetDragSessionCache,
} from '../session';

class FakeDataTransfer {
  constructor(initial = {}) {
    this.data = new Map(Object.entries(initial));
  }

  get types() {
    return [...this.data.keys()];
  }

  getData(type) {
    return this.data.get(type) || '';
  }

  setData(type, value) {
    this.data.set(type, String(value));
  }
}

beforeEach(() => {
  window.localStorage.clear();
  window.sessionStorage.clear();
  resetDragSessionCache();
});

test('writes the v1 creative envelope and legacy MIME data together', () => {
  const transfer = new FakeDataTransfer();

  expect(writeDragData(transfer, {
    kind: 'creative',
    ids: [7, '7', 8],
    payload: {
      creativeId: '7',
      treeId: 'creative-7',
      parentId: null,
      level: 1,
      isRoot: true,
    },
  })).toBe(true);

  const envelope = JSON.parse(transfer.getData(DND_MIME_TYPE));
  const legacy = JSON.parse(transfer.getData(LEGACY_MIME_TYPES.creative));

  expect(envelope).toMatchObject({
    v: 1,
    kind: 'creative',
    ids: ['7', '8'],
    token: window.localStorage.getItem(DRAG_TOKEN_STORAGE_KEY),
    sourceWindowId: window.sessionStorage.getItem(WINDOW_ID_SESSION_KEY),
  });
  expect(legacy).toMatchObject({
    creativeId: '7',
    treeId: 'creative-7',
    selectedCreativeIds: ['7', '8'],
    token: envelope.token,
    sourceWindowId: envelope.sourceWindowId,
  });
  expect(transfer.getData('text/plain')).toBe(transfer.getData(LEGACY_MIME_TYPES.creative));
  expect(getDragKind(transfer)).toBe('creative');
  expect(readDragData(transfer)).toEqual({
    kind: 'creative',
    ids: ['7', '8'],
    payload: expect.objectContaining({
      creativeId: '7',
      treeId: 'creative-7',
      sourceWindowId: envelope.sourceWindowId,
    }),
  });
});

test.each([
  ['topic', ['5'], { sourceCreativeId: '3' }, LEGACY_MIME_TYPES.topic],
  ['context', ['6'], {}, LEGACY_MIME_TYPES.context],
  ['comments', ['7', '8'], {}, LEGACY_MIME_TYPES.comments],
  ['agent', ['9'], { name: 'Agent' }, LEGACY_MIME_TYPES.agent],
])('round-trips %s data while preserving its legacy MIME', (kind, ids, payload, mime) => {
  const transfer = new FakeDataTransfer();
  expect(writeDragData(transfer, { kind, ids, payload })).toBe(true);
  expect(transfer.types).toContain(mime);
  expect(getDragKind(transfer)).toBe(kind);
  expect(readDragData(transfer)).toEqual({
    kind,
    ids,
    payload: expect.objectContaining(payload),
  });
});

test('normalizes each legacy MIME without requiring the common envelope', () => {
  window.localStorage.setItem(DRAG_TOKEN_STORAGE_KEY, 'token');
  resetDragSessionCache();

  const cases = [
    [
      new FakeDataTransfer({
        [LEGACY_MIME_TYPES.creative]: JSON.stringify({
          creativeId: 1,
          treeId: 'creative-1',
          selectedCreativeIds: [2, 1, 2],
          token: 'token',
          sourceWindowId: 'source',
        }),
      }),
      { kind: 'creative', ids: ['2', '1'] },
    ],
    [
      new FakeDataTransfer({
        [LEGACY_MIME_TYPES.topic]: JSON.stringify({ topicId: 3, sourceCreativeId: 4 }),
      }),
      { kind: 'topic', ids: ['3'], payload: { sourceCreativeId: 4 } },
    ],
    [
      new FakeDataTransfer({ [LEGACY_MIME_TYPES.context]: '5' }),
      { kind: 'context', ids: ['5'], payload: {} },
    ],
    [
      new FakeDataTransfer({
        [LEGACY_MIME_TYPES.comments]: JSON.stringify([6, '6', 7]),
      }),
      { kind: 'comments', ids: ['6', '7'], payload: {} },
    ],
    [
      new FakeDataTransfer({
        [LEGACY_MIME_TYPES.agent]: JSON.stringify({ id: 8, name: 'Agent' }),
      }),
      { kind: 'agent', ids: ['8'], payload: { name: 'Agent' } },
    ],
  ];

  cases.forEach(([transfer, expected]) => {
    expect(readDragData(transfer)).toMatchObject(expected);
  });
});

test('detects topic-id legacy data and never reads payload during kind detection', () => {
  const topicTransfer = new FakeDataTransfer({ 'application/x-topic-id': '12' });
  expect(getDragKind(topicTransfer)).toBe('topic');
  expect(readDragData(topicTransfer)).toEqual({
    kind: 'topic',
    ids: ['12'],
    payload: {},
  });

  const typesOnly = {
    types: [LEGACY_MIME_TYPES.context],
    getData: () => { throw new Error('getData must not run'); },
  };
  expect(getDragKind(typesOnly)).toBe('context');
  expect(getDragKind(null)).toBeNull();
});

test('prefers a valid common envelope and falls back from an invalid one', () => {
  window.localStorage.setItem(DRAG_TOKEN_STORAGE_KEY, 'token');
  resetDragSessionCache();

  const common = new FakeDataTransfer({
    [DND_MIME_TYPE]: JSON.stringify({
      v: 1,
      kind: 'agent',
      ids: [9],
      payload: { name: 'Common' },
      token: 'token',
      sourceWindowId: 'window',
    }),
    [LEGACY_MIME_TYPES.context]: '10',
  });
  expect(readDragData(common)).toEqual({
    kind: 'agent',
    ids: ['9'],
    payload: { name: 'Common', sourceWindowId: 'window' },
  });

  common.setData(DND_MIME_TYPE, '{bad json');
  expect(readDragData(common)).toEqual({ kind: 'context', ids: ['10'], payload: {} });
});

test('rejects malformed, empty, and untrusted data', () => {
  const error = jest.spyOn(console, 'error').mockImplementation(() => {});
  window.localStorage.setItem(DRAG_TOKEN_STORAGE_KEY, 'expected');
  resetDragSessionCache();

  const invalidCommonValues = [
    null,
    { v: 2, kind: 'creative', ids: ['1'], payload: {}, token: 'expected' },
    { v: 1, kind: 'unknown', ids: ['1'], payload: {}, token: 'expected' },
    { v: 1, kind: 'creative', ids: '1', payload: {}, token: 'expected' },
    { v: 1, kind: 'creative', ids: [], payload: {}, token: 'expected' },
    { v: 1, kind: 'creative', ids: ['1'], payload: [], token: 'expected' },
    { v: 1, kind: 'creative', ids: ['1'], payload: {}, token: 'wrong' },
  ];
  invalidCommonValues.forEach((value) => {
    const transfer = new FakeDataTransfer({ [DND_MIME_TYPE]: JSON.stringify(value) });
    expect(readDragData(transfer)).toBeNull();
  });

  const invalidLegacyValues = [
    new FakeDataTransfer({
      [LEGACY_MIME_TYPES.creative]: JSON.stringify({
        creativeId: 1,
        treeId: 'creative-1',
        token: 'wrong',
      }),
    }),
    new FakeDataTransfer({ [LEGACY_MIME_TYPES.topic]: '{}' }),
    new FakeDataTransfer({ [LEGACY_MIME_TYPES.context]: '' }),
    new FakeDataTransfer({ [LEGACY_MIME_TYPES.comments]: '{}' }),
    new FakeDataTransfer({ [LEGACY_MIME_TYPES.agent]: '{}' }),
  ];
  invalidLegacyValues.forEach((transfer) => expect(readDragData(transfer)).toBeNull());

  expect(readDragData({
    types: [LEGACY_MIME_TYPES.context],
    getData: () => { throw new Error('blocked'); },
  })).toBeNull();
  expect(error).toHaveBeenCalled();
  error.mockRestore();
});

test('rejects invalid writes', () => {
  expect(writeDragData(null, { kind: 'creative', ids: ['1'], payload: {} })).toBe(false);
  expect(writeDragData({}, { kind: 'creative', ids: ['1'], payload: {} })).toBe(false);
  expect(writeDragData(new FakeDataTransfer(), null)).toBe(false);
  expect(writeDragData(new FakeDataTransfer(), { kind: 'unknown', ids: ['1'] }))
    .toBe(false);
  expect(writeDragData(new FakeDataTransfer(), { kind: 'creative', ids: ['1'] }))
    .toBe(false);
  expect(writeDragData(new FakeDataTransfer(), {
    kind: 'creative', ids: ['1'], payload: [],
  })).toBe(false);
  expect(writeDragData(new FakeDataTransfer(), { kind: 'creative', ids: [] }))
    .toBe(false);
});

test('does not expose an unverifiable creative legacy payload', () => {
  const error = jest.spyOn(console, 'error').mockImplementation(() => {});
  jest.spyOn(window.Storage.prototype, 'setItem').mockImplementation(() => {
    throw new Error('blocked');
  });
  const transfer = new FakeDataTransfer();

  expect(writeDragData(transfer, {
    kind: 'creative',
    ids: ['1'],
    payload: { creativeId: '1', treeId: 'creative-1' },
  })).toBe(false);
  expect(transfer.types).toEqual([]);
  expect(error).toHaveBeenCalled();
  error.mockRestore();
  jest.restoreAllMocks();
});
