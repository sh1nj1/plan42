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
    window.sessionStorage.clear()
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
      updatedAt: 1000,
    })
    expect(entry).toHaveBeenCalledTimes(1)
    expect(drafts.snapshot(null)).toEqual({
      text: null,
      revision: null,
      updatedAt: null,
    })

    entry.mockRestore()
    expect(drafts.snapshot('missing')).toEqual({
      text: null,
      revision: null,
      updatedAt: null,
    })
    drafts.set('blank', '', { preserveBlank: true })
    expect(drafts.snapshot('blank')).toEqual({
      text: null,
      revision: drafts.revision('blank'),
      updatedAt: drafts.updatedAt('blank'),
    })
    drafts.set('raw', 'draft to move')
    drafts.move('raw', 'effective')
    expect(drafts.snapshot('raw')).toEqual({
      text: null,
      revision: null,
      updatedAt: null,
    })

    drafts.set('cleared', 'draft to clear')
    drafts.clear('cleared')
    expect(drafts.snapshot('cleared')).toEqual({
      text: null,
      revision: null,
      updatedAt: drafts._entry('cleared').updatedAt,
    })
  })

  test('compares resolved drafts across chat keys', () => {
    drafts.set('raw', 'raw draft')
    expect(drafts.isNewer('raw', 'effective')).toBe(true)
    expect(drafts.isNewer('raw', null)).toBe(true)
    expect(drafts.isNewer(null, 'effective')).toBe(false)
    expect(drafts.isNewer('missing', 'effective')).toBe(false)

    drafts.set('effective', 'canonical draft')
    expect(drafts.isNewer('raw', 'effective')).toBe(false)
  })

  test('orders a submission backup after the regular draft it supersedes', () => {
    jest.spyOn(Date, 'now').mockReturnValue(1000)
    drafts.set('101', 'older regular draft')

    drafts.saveSubmissionBackup('101', 'newer failed submission')

    expect(drafts.latestSubmissionBackup('101')?.updatedAt).toBe(1001)
  })

  test('uses a captured timestamp to preserve submission-time ordering', () => {
    jest.spyOn(Date, 'now').mockReturnValue(1000)
    drafts.set('101', 'regular draft written after submission')

    drafts.saveSubmissionBackup('101', 'failed submission', { updatedAt: 999 })

    expect(drafts.latestSubmissionBackup('101')?.updatedAt).toBe(999)
  })

  test('stores submission backups independently and removes exact backups', () => {
    let now = 1000
    jest.spyOn(Date, 'now').mockImplementation(() => now)
    expect(drafts.saveSubmissionBackup(null, 'draft')).toBeNull()
    expect(drafts.saveSubmissionBackup('101', '  ')).toBeNull()
    expect(drafts.latestSubmissionBackup(null)).toBeNull()

    const firstKey = drafts.saveSubmissionBackup('101', 'first submission')
    now += 1
    const secondKey = drafts.saveSubmissionBackup('101', 'second submission')

    expect(drafts.latestSubmissionBackup('101')).toEqual({
      key: secondKey,
      text: 'second submission',
      updatedAt: 1001,
    })
    drafts.removeSubmissionBackup('unrelated-key')
    drafts.removeSubmissionBackup(secondKey, 'collavre_chat_drafts_other')
    expect(drafts.latestSubmissionBackup('101')?.key).toBe(secondKey)
    drafts.removeSubmissionBackup(secondKey)
    expect(window.sessionStorage.getItem(firstKey)).toBeNull()
    expect(drafts.latestSubmissionBackup('101')).toBeNull()
    drafts.clearSubmissionBackups('101')
    drafts.clearSubmissionBackups(null)
    expect(drafts.latestSubmissionBackup('101')).toBeNull()

    now += 1
    const tiedFirst = drafts.saveSubmissionBackup('101', 'tied first')
    const tiedSecond = drafts.saveSubmissionBackup('101', 'tied second')
    expect(window.sessionStorage.getItem(tiedFirst)).toBeNull()
    expect(drafts.latestSubmissionBackup('101')?.key).toBe(tiedSecond)

    const prefix = drafts._backupPrefix('tied')
    window.sessionStorage.setItem(`${prefix}a`, JSON.stringify({ text: 'a', updatedAt: now }))
    window.sessionStorage.setItem(`${prefix}b`, JSON.stringify({ text: 'b', updatedAt: now }))
    expect(drafts.latestSubmissionBackup('tied')?.text).toBe('b')
  })

  test('moves submission backups without changing their ordering metadata', () => {
    expect(drafts.moveSubmissionBackups(null, 'effective')).toEqual(new Map())
    expect(drafts.moveSubmissionBackups('raw', 'raw')).toEqual(new Map())
    const sourceKey = drafts.saveSubmissionBackup('raw', 'linked submission')
    const source = drafts.latestSubmissionBackup('raw')

    const moved = drafts.moveSubmissionBackups('raw', 'effective')

    expect(moved.get(sourceKey)).toBe(drafts.latestSubmissionBackup('effective').key)
    expect(drafts.latestSubmissionBackup('effective')).toMatchObject({
      text: 'linked submission',
      updatedAt: source.updatedAt,
    })
    expect(drafts.latestSubmissionBackup('raw')).toBeNull()
  })

  test('keeps the newest submission backup when linked keys converge', () => {
    let now = 1000
    jest.spyOn(Date, 'now').mockImplementation(() => now)
    drafts.saveSubmissionBackup('older-raw', 'older raw')
    now += 1
    const newerTargetKey = drafts.saveSubmissionBackup('newer-target', 'newer target')

    expect(drafts.moveSubmissionBackups('older-raw', 'newer-target')).toEqual(new Map())
    expect(drafts.latestSubmissionBackup('newer-target')?.key).toBe(newerTargetKey)
    expect(drafts.latestSubmissionBackup('older-raw')).toBeNull()

    drafts.saveSubmissionBackup('older-target', 'older target')
    now += 1
    const newerSourceKey = drafts.saveSubmissionBackup('newer-raw', 'newer raw')
    const moved = drafts.moveSubmissionBackups('newer-raw', 'older-target')
    expect(moved.get(newerSourceKey)).toBe(drafts.latestSubmissionBackup('older-target').key)
    expect(drafts.latestSubmissionBackup('older-target')?.text).toBe('newer raw')

    const tiedSourceKey = drafts.saveSubmissionBackup('tied-raw', 'tied raw')
    const tiedTargetKey = drafts.saveSubmissionBackup('tied-target', 'tied target')
    expect(drafts.moveSubmissionBackups('tied-raw', 'tied-target')).toEqual(new Map())
    expect(drafts.latestSubmissionBackup('tied-target')?.key).toBe(tiedTargetKey)
    expect(window.sessionStorage.getItem(tiedSourceKey)).toBeNull()
  })

  test('keeps a submission backup when its move cannot be persisted', () => {
    const storage = {
      get length() { return window.localStorage.length },
      key: (index) => window.localStorage.key(index),
      getItem: (key) => window.localStorage.getItem(key),
      setItem: (key, value) => {
        if (key.startsWith('collavre_chat_drafts_9_pending:effective:')) {
          throw new Error('quota')
        }
        window.localStorage.setItem(key, value)
      },
      removeItem: (key) => window.localStorage.removeItem(key),
    }
    const failingDrafts = new ChatDrafts(storage)
    failingDrafts.saveSubmissionBackup('raw', 'keep at source')

    expect(failingDrafts.moveSubmissionBackups('raw', 'effective')).toEqual(new Map())
    expect(failingDrafts.latestSubmissionBackup('raw')?.text).toBe('keep at source')
    expect(failingDrafts.latestSubmissionBackup('effective')).toBeNull()

    window.localStorage.clear()
    const droppedStorage = {
      get length() { return window.localStorage.length },
      key: storage.key,
      getItem: storage.getItem,
      setItem: (key, value) => {
        if (!key.startsWith('collavre_chat_drafts_9_pending:effective:')) {
          window.localStorage.setItem(key, value)
        }
      },
      removeItem: storage.removeItem,
    }
    const droppedDrafts = new ChatDrafts(droppedStorage)
    droppedDrafts.saveSubmissionBackup('raw', 'verify destination')
    expect(droppedDrafts.moveSubmissionBackups('raw', 'effective')).toEqual(new Map())
    expect(droppedDrafts.latestSubmissionBackup('raw')?.text).toBe('verify destination')

    const values = new Map()
    const stickySourceStorage = {
      get length() { return values.size },
      key: (index) => [...values.keys()][index] || null,
      getItem: (key) => values.get(key) ?? null,
      setItem: (key, value) => values.set(key, value),
      removeItem: (key) => {
        if (!key.startsWith('collavre_chat_drafts_9_pending:raw:')) values.delete(key)
      },
    }
    const stickyDrafts = new ChatDrafts(stickySourceStorage)
    stickyDrafts.saveSubmissionBackup('raw', 'source cannot be removed')
    expect(stickyDrafts.moveSubmissionBackups('raw', 'effective')).toEqual(new Map())
    expect(stickyDrafts.latestSubmissionBackup('raw')?.text).toBe('source cannot be removed')
    expect(stickyDrafts.latestSubmissionBackup('effective')).toBeNull()

    values.clear()
    const stickyTargetStorage = {
      get length() { return values.size },
      key: stickySourceStorage.key,
      getItem: stickySourceStorage.getItem,
      setItem: stickySourceStorage.setItem,
      removeItem: (key) => {
        if (!key.startsWith('collavre_chat_drafts_9_pending:effective:')) values.delete(key)
      },
    }
    const stickyTargetDrafts = new ChatDrafts(stickyTargetStorage)
    let now = 1000
    jest.spyOn(Date, 'now').mockImplementation(() => now)
    stickyTargetDrafts.saveSubmissionBackup('effective', 'target cannot be removed')
    now += 1
    stickyTargetDrafts.saveSubmissionBackup('raw', 'newer source')
    expect(stickyTargetDrafts.moveSubmissionBackups('raw', 'effective')).toEqual(new Map())
    expect(stickyTargetDrafts.latestSubmissionBackup('effective')?.text)
      .toBe('target cannot be removed')
    expect(stickyTargetDrafts.latestSubmissionBackup('raw')?.text).toBe('newer source')
  })

  test('prunes expired and malformed submission backups', () => {
    const prefix = drafts._backupPrefix('101')
    const expiredKey = `${prefix}expired`
    const malformedKey = `${prefix}malformed`
    const blankKey = `${prefix}blank`
    window.sessionStorage.setItem(expiredKey, JSON.stringify({
      text: 'expired submission',
      updatedAt: Date.now() - 8 * 24 * 60 * 60 * 1000,
    }))
    window.sessionStorage.setItem(malformedKey, '{bad')
    window.sessionStorage.setItem(blankKey, JSON.stringify({ text: '', updatedAt: Date.now() }))
    expect(drafts.latestSubmissionBackup('101')).toBeNull()
    const validKey = drafts.saveSubmissionBackup('101', 'valid submission')

    expect(drafts.latestSubmissionBackup('101')?.key).toBe(validKey)
    expect(window.sessionStorage.getItem(expiredKey)).toBeNull()
    expect(window.sessionStorage.getItem(malformedKey)).toBeNull()
    expect(window.sessionStorage.getItem(blankKey)).toBeNull()

    drafts.clearAll({ broadcast: false })
    expect(window.sessionStorage.getItem(validKey)).toBeNull()
  })

  test('bounds submission backups to the newest fifty entries', () => {
    let now = 1000
    jest.spyOn(Date, 'now').mockImplementation(() => (now += 1))
    const keys = Array.from({ length: 51 }, (_, index) => (
      drafts.saveSubmissionBackup(`chat-${index}`, `submission ${index}`)
    ))

    expect(window.sessionStorage.getItem(keys[0])).toBeNull()
    expect(window.sessionStorage.getItem(keys[50])).not.toBeNull()
    expect(drafts.latestSubmissionBackup('chat-50')?.text).toBe('submission 50')
  })

  test('submission backups tolerate unavailable storage', () => {
    const broken = {
      length: 1,
      key: () => 'collavre_chat_drafts_9_pending:101:backup',
      getItem: () => { throw new Error('denied') },
      setItem: () => { throw new Error('quota') },
      removeItem: () => { throw new Error('denied') },
    }
    const brokenDrafts = new ChatDrafts(broken)

    expect(brokenDrafts.saveSubmissionBackup('101', 'draft')).toBeNull()
    expect(brokenDrafts.latestSubmissionBackup('101')).toBeNull()
    expect(() => brokenDrafts.removeSubmissionBackup(
      'collavre_chat_drafts_9_pending:101:backup',
    )).not.toThrow()
    expect(() => brokenDrafts.clearSubmissionBackups('101')).not.toThrow()

    const writeOnlyFailure = {
      length: 0,
      key: () => null,
      getItem: () => null,
      setItem: () => { throw new Error('quota') },
      removeItem: () => {},
    }
    expect(new ChatDrafts(null, writeOnlyFailure)
      .saveSubmissionBackup('101', 'draft')).toBeNull()
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

  test('clearing a draft does not hide text concurrently saved from the same revision', () => {
    jest.spyOn(Date, 'now').mockReturnValue(1000)
    drafts.set('101', 'shared draft')

    const clearingTab = new ChatDrafts()
    const writingTab = new ChatDrafts()
    clearingTab._writerId = 'z-clear'
    writingTab._writerId = 'a-write'
    const append = clearingTab._append.bind(clearingTab)
    jest.spyOn(clearingTab, '_append').mockImplementation((id, entry) => {
      if (entry.deleted) writingTab.set('101', 'concurrent new text')
      return append(id, entry)
    })

    clearingTab.clear('101')

    expect(drafts.get('101')).toBe('concurrent new text')
    expect(drafts.revision('101')).toContain('a-write')
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

  test('retries a move when a newer source survives the move marker', () => {
    jest.spyOn(Date, 'now').mockReturnValue(1000)
    drafts.set('raw', 'first source')

    const writingTab = new ChatDrafts()
    const append = drafts._append.bind(drafts)
    let sourceWritten = false
    const writeNewerSource = () => {
      sourceWritten = true
      writingTab.set('raw', 'newer source')
    }
    jest.spyOn(drafts, '_append').mockImplementation((id, entry) => {
      if (id === 'raw' && entry.movedTo && !sourceWritten) writeNewerSource()
      return append(id, entry)
    })

    drafts.move('raw', 'effective')

    expect(drafts.get('raw')).toBeNull()
    expect(drafts.get('effective')).toBe('newer source')
  })

  test('retries a move when a concurrent source clear survives the marker', () => {
    jest.spyOn(Date, 'now').mockReturnValue(1000)
    drafts._writerId = 'z-marker'
    drafts.set('raw', 'source to clear')

    const clearingTab = new ChatDrafts()
    clearingTab._writerId = 'a-clear'
    const append = drafts._append.bind(drafts)
    let sourceCleared = false
    const clearSource = () => {
      sourceCleared = true
      clearingTab.clear('raw')
    }
    jest.spyOn(drafts, '_append').mockImplementation((id, entry) => {
      if (id === 'raw' && entry.movedTo && !sourceCleared) clearSource()
      return append(id, entry)
    })

    drafts.move('raw', 'effective')

    expect(drafts.get('raw')).toBeNull()
    expect(drafts.get('effective')).toBeNull()
  })

  test('reports an incomplete move after concurrent source writes exhaust retries', () => {
    jest.spyOn(Date, 'now').mockReturnValue(1000)
    drafts.set('raw', 'first source')

    const writingTab = new ChatDrafts()
    const append = drafts._append.bind(drafts)
    let sourceWrites = 0
    const writeNewerSource = () => {
      sourceWrites += 1
      writingTab.set('raw', `newer source ${sourceWrites}`)
    }
    jest.spyOn(drafts, '_append').mockImplementation((id, entry) => {
      if (id === 'raw' && entry.movedTo) writeNewerSource()
      return append(id, entry)
    })

    expect(drafts.move('raw', 'effective')).toBe(false)
    expect(drafts.get('raw')).toBe('newer source 3')
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

    expect(drafts.move('raw', 'effective')).toBe(false)

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

  test('a blank migration does not hide the first concurrent destination draft', () => {
    jest.spyOn(Date, 'now').mockReturnValue(1000)
    drafts._writerId = 'z-clear'
    drafts.set('raw', '', { preserveBlank: true })

    const writingTab = new ChatDrafts()
    writingTab._writerId = 'a-write'
    const entry = drafts._entry.bind(drafts)
    let destinationWritten = false
    jest.spyOn(drafts, '_entry').mockImplementation((id) => {
      const current = entry(id)
      if (id === 'effective' && !current && !destinationWritten) {
        destinationWritten = true
        writingTab.set('effective', 'first canonical draft')
      }
      return current
    })

    drafts.move('raw', 'effective')

    expect(drafts.get('raw')).toBeNull()
    expect(drafts.get('effective')).toBe('first canonical draft')
    expect(drafts.revision('effective')).toContain('a-write')
  })

  test('a migrated blank does not hide text concurrently saved from the destination revision', () => {
    let now = 1000
    jest.spyOn(Date, 'now').mockImplementation(() => now)
    drafts._writerId = 'z-clear'
    drafts.set('effective', 'canonical draft')
    now += 1
    drafts.set('raw', '', { preserveBlank: true })

    const writingTab = new ChatDrafts()
    writingTab._writerId = 'a-write'
    const append = drafts._append.bind(drafts)
    jest.spyOn(drafts, '_append').mockImplementation((id, entry) => {
      if (id === 'effective' && entry.deleted) {
        writingTab.set('effective', 'concurrent canonical text')
      }
      return append(id, entry)
    })

    drafts.move('raw', 'effective')

    expect(drafts.get('effective')).toBe('concurrent canonical text')
    expect(drafts.revision('effective')).toContain('a-write')
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
