/**
 * @jest-environment jsdom
 */

import { jest } from '@jest/globals'
import { ChatDrafts } from '../chat_drafts'

describe('ChatDrafts', () => {
  let drafts

  const storedValues = (prefix) => Array.from(
    { length: window.localStorage.length },
    (_, index) => window.localStorage.key(index),
  )
    .filter((key) => key.startsWith(prefix))
    .map((key) => window.localStorage.getItem(key))

  beforeEach(() => {
    window.localStorage.clear()
    document.body.dataset.currentUserId = '9'
    drafts = new ChatDrafts()
  })

  afterEach(() => {
    jest.restoreAllMocks()
    delete document.body.dataset.currentUserId
  })

  test('set + get roundtrip, keyed per chat', () => {
    drafts.set('101', 'hello draft')
    drafts.set(202, 'second draft')
    expect(drafts.get('101')).toBe('hello draft')
    expect(drafts.get('202')).toBe('second draft')
    expect(drafts.get('999')).toBeNull()
  })

  test('stores concurrent chats under independent keys', () => {
    const firstTab = new ChatDrafts()
    const otherTab = new ChatDrafts()

    firstTab.set('101', 'draft from first tab')
    otherTab.set('202', 'draft from other tab')

    expect(drafts.get('101')).toBe('draft from first tab')
    expect(drafts.get('202')).toBe('draft from other tab')
    expect(storedValues('collavre_chat_drafts_9:101:').join()).toContain('first tab')
    expect(storedValues('collavre_chat_drafts_9:202:').join()).toContain('other tab')
    expect(window.localStorage.getItem('collavre_chat_drafts_9')).toBeNull()
  })

  test('uses a deterministic version tie-breaker for the same timestamp', () => {
    jest.spyOn(Date, 'now').mockReturnValue(1000)
    const earlier = { text: 'earlier', updatedAt: 1000, version: '1000-a' }
    const later = { text: 'later', updatedAt: 1000, version: '1000-b' }

    expect(drafts._append('101', later)).toBe(true)
    expect(drafts._append('101', earlier)).toBe(true)

    expect(drafts.get('101')).toBe('later')
    expect(drafts.revision('101')).toBe('1000-b')
  })

  test('snapshots text and revision from one resolved operation', () => {
    const resolved = { text: 'submitted draft', updatedAt: 1000, version: 'v1' }
    const newer = { text: 'concurrent draft', updatedAt: 1001, version: 'v2' }
    const entry = jest.spyOn(drafts, '_entry')
      .mockImplementationOnce(() => resolved)
      .mockImplementation(() => newer)

    expect(drafts.snapshot('101')).toEqual({
      text: 'submitted draft',
      revision: 'v1',
    })
    expect(entry).toHaveBeenCalledTimes(1)
    expect(drafts.snapshot(null)).toEqual({ text: null, revision: null })

    entry.mockRestore()
    expect(drafts.snapshot('missing')).toEqual({ text: null, revision: null })
    drafts.set('blank', '', { preserveBlank: true })
    expect(drafts.snapshot('blank')).toEqual({
      text: null,
      revision: drafts.revision('blank'),
    })
    drafts.set('raw', 'draft to move')
    drafts.move('raw', 'effective')
    expect(drafts.snapshot('raw')).toEqual({ text: null, revision: null })
  })

  test('a clear tombstone survives obsolete aggregate cleanup', () => {
    let now = 1000
    jest.spyOn(Date, 'now').mockImplementation(() => now)
    drafts.set('101', 'clear me')
    now += 1
    drafts.clear('101')

    window.localStorage.setItem('collavre_chat_drafts_9', JSON.stringify({
      101: { text: 'old tab draft', updatedAt: 1000 },
    }))

    expect(drafts.get('101')).toBeNull()
    expect(window.localStorage.getItem('collavre_chat_drafts_9')).toBeNull()
  })

  test('a conditional tombstone does not hide a newer concurrent operation', () => {
    let now = 1000
    jest.spyOn(Date, 'now').mockImplementation(() => now)
    drafts.set('101', 'eviction candidate')
    const candidate = drafts._entry('101')
    now += 1
    drafts.set('101', 'newer concurrent input')
    now += 1
    drafts._append('101', drafts._newEntry('', candidate, {
      deleted: true,
      deletesThrough: drafts._versionOf(candidate),
    }))

    expect(drafts.get('101')).toBe('newer concurrent input')
    drafts._compact('101')
    expect(drafts.get('101')).toBe('newer concurrent input')
  })

  test('compaction keeps a tombstone that blocks a delayed stale operation', () => {
    let now = 1000
    jest.spyOn(Date, 'now').mockImplementation(() => now)
    drafts.set('101', 'draft to clear')
    const stale = drafts._entry('101')
    now += 1
    drafts.clear('101')

    expect(drafts.get('101')).toBeNull()
    expect(drafts._append('101', stale)).toBe(true)
    expect(drafts.get('101')).toBeNull()
  })

  test('bounds tombstones during repeated set and clear cycles', () => {
    for (let index = 0; index < 1000; index += 1) {
      drafts.set('101', `draft ${index}`)
      drafts.clear('101')
    }

    expect(storedValues('collavre_chat_drafts_9:101:')).toHaveLength(1)
  })

  test('retains each chat deletion guard until TTL cleanup', () => {
    drafts.set('victim', 'draft to clear')
    const stale = drafts._entry('victim')
    drafts.clear('victim')
    for (let index = 0; index < 50; index += 1) {
      drafts.set(`other-${index}`, `draft ${index}`)
      drafts.clear(`other-${index}`)
    }

    drafts._append('victim', stale)

    expect(drafts.get('victim')).toBeNull()
  })

  test('compaction retains only the strongest deletion guard', () => {
    jest.spyOn(Date, 'now').mockReturnValue(1000)
    const ceiling = (updatedAt, version) => ({ updatedAt, version })
    const tombstones = [
      { text: '', updatedAt: 11, version: 't1', deleted: true, deletesThrough: ceiling(10, 'v1') },
      { text: '', updatedAt: 31, version: 't2', deleted: true, deletesThrough: ceiling(30, 'v3') },
      { text: '', updatedAt: 21, version: 't3', deleted: true, deletesThrough: ceiling(20, 'v2') },
      { text: '', updatedAt: 32, version: 't4', deleted: true, deletesThrough: ceiling(30, 'v3') },
      { text: '', updatedAt: 30, version: 't0', deleted: true, deletesThrough: ceiling(30, 'v3') },
    ]
    tombstones.forEach((entry) => drafts._append('101', entry))

    drafts._compact('101')

    expect(storedValues('collavre_chat_drafts_9:101:')).toEqual([
      JSON.stringify(tombstones[3]),
    ])
  })

  test('exposes a monotonic update timestamp per draft', () => {
    jest.spyOn(Date, 'now').mockReturnValue(1000)
    expect(drafts.updatedAt(null)).toBeNull()
    expect(drafts.updatedAt('missing')).toBeNull()
    expect(drafts.revision(null)).toBeNull()
    expect(drafts.revision('missing')).toBeNull()

    drafts.set('101', 'same text')
    const firstUpdatedAt = drafts.updatedAt('101')
    drafts.set('101', 'same text')

    expect(firstUpdatedAt).toBe(1000)
    expect(drafts.updatedAt('101')).toBe(1001)
  })

  test('storage key is namespaced by current user id', () => {
    drafts.set('101', 'hello')
    expect(storedValues('collavre_chat_drafts_9:101:').join()).toContain('hello')
  })

  test('recomputes the storage namespace when the current user changes', () => {
    drafts.set('101', 'user 9 draft')

    document.body.dataset.currentUserId = '10'
    expect(drafts.get('101')).toBeNull()
    drafts.set('101', 'user 10 draft')

    expect(storedValues('collavre_chat_drafts_9:101:').join()).toContain('user 9 draft')
    expect(storedValues('collavre_chat_drafts_10:101:').join()).toContain('user 10 draft')
  })

  test('exposes the current namespace for asynchronous ownership checks', () => {
    expect(drafts.namespace()).toBe('collavre_chat_drafts_9')
    document.body.dataset.currentUserId = '10'
    expect(drafts.namespace()).toBe('collavre_chat_drafts_10')
  })

  test('falls back to guest namespace without a current user id', () => {
    delete document.body.dataset.currentUserId
    const guestDrafts = new ChatDrafts()
    guestDrafts.set('101', 'guest draft')
    expect(storedValues('collavre_chat_drafts_guest:101:').join()).toContain('guest draft')
  })

  test('blank text hides the entry behind a deletion tombstone', () => {
    drafts.set('101', 'hello')
    drafts.set('101', '   ')
    expect(drafts.get('101')).toBeNull()
    expect(storedValues('collavre_chat_drafts_9:101:').some((value) => (
      JSON.parse(value).deleted === true
    ))).toBe(true)
  })

  test('set with blank text on a missing entry is a no-op (no write)', () => {
    drafts.set('101', '')
    expect(storedValues('collavre_chat_drafts_9:101:')).toEqual([])
  })

  test('clear removes a single draft', () => {
    drafts.set('101', 'a')
    drafts.set('102', 'b')
    drafts.clear('101')
    expect(drafts.get('101')).toBeNull()
    expect(drafts.get('102')).toBe('b')
  })

  test('moves a draft to an empty destination', () => {
    drafts.set('raw', 'loading-window draft')

    drafts.move('raw', 'effective')

    expect(drafts.get('raw')).toBeNull()
    expect(drafts.get('effective')).toBe('loading-window draft')

    drafts.move('raw', 'effective')
    expect(drafts.get('effective')).toBe('loading-window draft')
  })

  test('retries a move when the source changes concurrently', () => {
    drafts.set('raw', 'first source')
    const sameEntry = drafts._sameEntry.bind(drafts)
    let changed = false
    jest.spyOn(drafts, '_sameEntry').mockImplementation((source, latest) => {
      if (!changed) {
        changed = true
        drafts.set('raw', 'newer source')
        return false
      }
      return sameEntry(source, latest)
    })

    drafts.move('raw', 'effective')

    expect(drafts.get('raw')).toBeNull()
    expect(drafts.get('effective')).toBe('newer source')
  })

  test('handles move marker write failure', () => {
    drafts.set('raw', 'source')
    const append = drafts._append.bind(drafts)
    jest.spyOn(drafts, '_append').mockImplementation((id, entry) => (
      entry.movedTo ? false : append(id, entry)
    ))
    expect(() => drafts.move('raw', 'effective')).not.toThrow()
    expect(drafts.get('raw')).toBe('source')
  })

  test('keeps the source when the move target cannot be stored', () => {
    drafts.set('raw', 'source')
    const append = drafts._append.bind(drafts)
    jest.spyOn(drafts, '_append').mockImplementation((id, entry) => (
      id === 'effective' ? false : append(id, entry)
    ))

    drafts.move('raw', 'effective')

    expect(drafts.get('raw')).toBe('source')
    expect(drafts.get('effective')).toBeNull()
  })

  test('moves only the newer draft when the destination already exists', () => {
    let now = 1000
    jest.spyOn(Date, 'now').mockImplementation(() => now)
    drafts.set('effective', 'older canonical draft')
    now += 1
    drafts.set('raw', 'newer loading-window draft')

    drafts.move('raw', 'effective')

    expect(drafts.get('raw')).toBeNull()
    expect(drafts.get('effective')).toBe('newer loading-window draft')
  })

  test('keeps a newer destination when removing a stale source draft', () => {
    let now = 1000
    jest.spyOn(Date, 'now').mockImplementation(() => now)
    drafts.set('raw', 'stale raw draft')
    now += 1
    drafts.set('effective', 'newer canonical draft')

    drafts.move('raw', 'effective')

    expect(drafts.get('raw')).toBeNull()
    expect(drafts.get('effective')).toBe('newer canonical draft')
  })

  test('moves a newer blank tombstone by clearing the destination', () => {
    let now = 1000
    jest.spyOn(Date, 'now').mockImplementation(() => now)
    drafts.set('effective', 'canonical draft')
    now += 1
    drafts.set('raw', '', { preserveBlank: true })

    expect(drafts.get('raw')).toBeNull()
    expect(drafts.updatedAt('raw')).toBe(1001)
    expect(drafts.revision('raw')).not.toBeNull()

    drafts.move('raw', 'effective')

    expect(drafts.get('raw')).toBeNull()
    expect(drafts.updatedAt('raw')).toBeNull()
    expect(drafts.revision('raw')).toBeNull()
    expect(drafts.get('effective')).toBeNull()
  })

  test('move ignores invalid, identical, and missing source ids', () => {
    drafts.set('101', 'existing draft')
    const stored = storedValues('collavre_chat_drafts_9:101:')

    drafts.move(null, '102')
    drafts.move('101', null)
    drafts.move('101', '101')
    drafts.move('missing', '102')

    expect(storedValues('collavre_chat_drafts_9:101:')).toEqual(stored)
  })

  test('clearAll removes the storage key', () => {
    drafts.set('101', 'a')
    drafts.clearAll()
    expect(storedValues('collavre_chat_drafts_9:101:')).toEqual([])
  })

  test('clearAll broadcasts its namespace for other tabs', () => {
    drafts.clearAll()
    const signal = window.localStorage.getItem('collavre_chat_drafts_clear')

    expect(JSON.parse(signal).namespace).toBe('collavre_chat_drafts_9')
    expect(drafts.wasCleared(new StorageEvent('storage', {
      key: 'collavre_chat_drafts_clear',
      newValue: signal,
    }))).toBe(true)
    expect(drafts.wasCleared(new StorageEvent('storage', {
      key: 'collavre_chat_drafts_clear',
      newValue: JSON.stringify({ namespace: 'collavre_chat_drafts_10' }),
    }))).toBe(false)
    expect(drafts.wasCleared(new StorageEvent('storage', {
      key: 'unrelated',
      newValue: signal,
    }))).toBe(false)
    expect(drafts.wasCleared(new StorageEvent('storage', {
      key: 'collavre_chat_drafts_clear',
      newValue: '{invalid',
    }))).toBe(false)
  })

  test('clearAll can skip the cross-tab broadcast', () => {
    drafts.set('101', 'a')
    drafts.clearAll({ broadcast: false })

    expect(storedValues('collavre_chat_drafts_9:101:')).toEqual([])
    expect(window.localStorage.getItem('collavre_chat_drafts_clear')).toBeNull()
  })

  test('ignores falsy chat ids', () => {
    drafts.set(null, 'x')
    drafts.set('', 'x')
    expect(drafts.get(null)).toBeNull()
    expect(drafts.get('')).toBeNull()
    expect(window.localStorage.getItem('collavre_chat_drafts_9')).toBeNull()
  })

  test('evicts the oldest drafts beyond MAX_DRAFTS (50)', () => {
    let now = 1_000_000
    jest.spyOn(Date, 'now').mockImplementation(() => (now += 1000))
    for (let i = 1; i <= 51; i++) drafts.set(`chat-${i}`, `draft ${i}`)
    expect(drafts.get('chat-1')).toBeNull()
    expect(drafts.get('chat-2')).toBe('draft 2')
    expect(drafts.get('chat-51')).toBe('draft 51')
  })

  test('discards the obsolete aggregate format on load', () => {
    window.localStorage.setItem('collavre_chat_drafts_9', JSON.stringify({
      old: { text: 'stale', updatedAt: Date.now() },
      fresh: { text: 'recent', updatedAt: Date.now() },
    }))

    expect(drafts.get('fresh')).toBeNull()
    expect(window.localStorage.getItem('collavre_chat_drafts_9')).toBeNull()
  })

  test('prunes expired independent operations while loading another chat', () => {
    const oldKey = 'collavre_chat_drafts_9:old:expired'
    window.localStorage.setItem(oldKey, JSON.stringify({
      text: 'stale sensitive text',
      updatedAt: Date.now() - 8 * 24 * 60 * 60 * 1000,
      version: 'expired',
    }))
    drafts.set('fresh', 'recent')

    expect(drafts.get('fresh')).toBe('recent')
    expect(window.localStorage.getItem(oldKey)).toBeNull()
  })

  test('survives corrupted stored JSON', () => {
    window.localStorage.setItem('collavre_chat_drafts_9', '{not json')
    expect(drafts.get('101')).toBeNull()
    expect(window.localStorage.getItem('collavre_chat_drafts_9')).toBeNull()
    drafts.set('101', 'recovered')
    expect(drafts.get('101')).toBe('recovered')
  })

  test('survives non-object stored JSON and malformed entries', () => {
    window.localStorage.setItem('collavre_chat_drafts_9', JSON.stringify(['array']))
    expect(drafts.get('101')).toBeNull()
    window.localStorage.setItem(
      'collavre_chat_drafts_9',
      JSON.stringify({ bad: { text: 42 }, worse: null }),
    )
    expect(drafts.get('bad')).toBeNull()
    expect(drafts.get('worse')).toBeNull()
    expect(window.localStorage.getItem('collavre_chat_drafts_9')).toBeNull()
  })

  test('survives a throwing storage backend', () => {
    const broken = {
      getItem: () => { throw new Error('denied') },
      setItem: () => { throw new Error('quota') },
      removeItem: () => { throw new Error('denied') },
    }
    const brokenDrafts = new ChatDrafts(broken)
    expect(() => brokenDrafts.set('101', 'x')).not.toThrow()
    expect(brokenDrafts.get('101')).toBeNull()
    expect(() => brokenDrafts.clearAll()).not.toThrow()
  })

  test('handles malformed independent entries and key enumeration failures', () => {
    window.localStorage.setItem('collavre_chat_drafts_9:bad-json:op', '{bad')
    window.localStorage.setItem(
      'collavre_chat_drafts_9:bad-entry:op',
      JSON.stringify({ text: 42, updatedAt: Date.now() }),
    )
    expect(drafts.get('bad-json')).toBeNull()
    expect(drafts._entries()).toEqual([])

    const unlistable = new ChatDrafts({
      length: 1,
      key: () => { throw new Error('denied') },
      getItem: () => null,
      setItem: () => {},
      removeItem: () => {},
    })
    expect(unlistable._keys()).toEqual([])
  })

  test('ignores an operation removed during key enumeration', () => {
    const disappearing = new ChatDrafts({
      length: 1,
      key: () => 'collavre_chat_drafts_9:101:gone',
      getItem: () => null,
      setItem: () => {},
      removeItem: () => {},
    })

    expect(disappearing.get('101')).toBeNull()
  })

  test('ignores an operation removed during entry enumeration', () => {
    let reads = 0
    const entry = JSON.stringify({ text: 'draft', updatedAt: Date.now(), version: 'v1' })
    const disappearing = new ChatDrafts({
      length: 1,
      key: () => 'collavre_chat_drafts_9:101:v1',
      getItem: () => ((reads += 1) === 1 ? entry : null),
      setItem: () => {},
      removeItem: () => {},
    })

    expect(disappearing._entries()).toEqual([])
  })

  test('removes operation keys with malformed encoded chat ids', () => {
    const key = 'collavre_chat_drafts_9:%E0%A4%A:v1'
    window.localStorage.setItem(key, JSON.stringify({
      text: 'draft',
      updatedAt: Date.now(),
      version: 'v1',
    }))

    expect(drafts._entries()).toEqual([])
    expect(window.localStorage.getItem(key)).toBeNull()

    const unremovable = new ChatDrafts({
      length: 1,
      key: () => key,
      getItem: () => JSON.stringify({
        text: 'draft',
        updatedAt: Date.now(),
        version: 'v1',
      }),
      setItem: () => {},
      removeItem: () => { throw new Error('denied') },
    })
    expect(unremovable._entries()).toEqual([])
  })

  test('skips invalid operations during compaction and selects the newest operation', () => {
    jest.spyOn(Date, 'now').mockReturnValue(1000)
    const older = { text: 'older', updatedAt: 1000, version: 'v1' }
    const newer = { text: 'newer', updatedAt: 1001, version: 'v2' }
    const stale = { text: 'stale', updatedAt: 999, version: 'v0' }
    drafts._append('101', older)
    drafts._append('101', newer)
    drafts._append('101', stale)
    window.localStorage.setItem('collavre_chat_drafts_9:101:invalid', '{bad')

    expect(drafts._entries()).toEqual([{ id: '101', entry: newer }])
    window.localStorage.setItem('collavre_chat_drafts_9:101:invalid-entry', '{bad')
    expect(drafts._entry('101')).toEqual(newer)
    window.localStorage.setItem('collavre_chat_drafts_9:101:invalid-again', '{bad')
    expect(() => drafts._compact('101')).not.toThrow()
  })

  test('handles storage failures while pruning and clearing independent entries', () => {
    const invalid = JSON.stringify({ text: 42, updatedAt: Date.now() })
    const backend = {
      length: 1,
      key: () => 'collavre_chat_drafts_9:101',
      getItem: (key) => (key.endsWith(':101') ? invalid : null),
      setItem: () => { throw new Error('quota') },
      removeItem: () => { throw new Error('denied') },
    }
    const failingDrafts = new ChatDrafts(backend)

    expect(failingDrafts.get('101')).toBeNull()
    expect(() => failingDrafts.clearAll()).not.toThrow()
  })

  test('bounds immutable append verification retries', () => {
    const entry = { text: 'draft', updatedAt: Date.now(), version: 'v1' }
    const noWriteStorage = {
      getItem: () => null,
      setItem: () => {},
      removeItem: () => {},
    }
    expect(new ChatDrafts(noWriteStorage)._append('101', entry)).toBe(false)
  })

  test('compares immutable operations and exact entry identity', () => {
    const entry = { text: 'draft', updatedAt: 1000, version: 'v1' }
    expect(drafts._compare(entry, null)).toBe(1)
    expect(drafts._compare(entry, { ...entry })).toBe(0)
    expect(drafts._sameEntry(entry, { ...entry })).toBe(true)
  })

})
