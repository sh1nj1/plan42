/**
 * @jest-environment jsdom
 */

import { jest } from '@jest/globals'
import { ChatDrafts } from '../chat_drafts'

describe('ChatDrafts', () => {
  let drafts

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

  test('storage key is namespaced by current user id', () => {
    drafts.set('101', 'hello')
    expect(window.localStorage.getItem('collavre_chat_drafts_9')).toContain('hello')
  })

  test('recomputes the storage namespace when the current user changes', () => {
    drafts.set('101', 'user 9 draft')

    document.body.dataset.currentUserId = '10'
    expect(drafts.get('101')).toBeNull()
    drafts.set('101', 'user 10 draft')

    expect(window.localStorage.getItem('collavre_chat_drafts_9')).toContain('user 9 draft')
    expect(window.localStorage.getItem('collavre_chat_drafts_10')).toContain('user 10 draft')
  })

  test('falls back to guest namespace without a current user id', () => {
    delete document.body.dataset.currentUserId
    const guestDrafts = new ChatDrafts()
    guestDrafts.set('101', 'guest draft')
    expect(window.localStorage.getItem('collavre_chat_drafts_guest')).toContain('guest draft')
  })

  test('blank text deletes the entry', () => {
    drafts.set('101', 'hello')
    drafts.set('101', '   ')
    expect(drafts.get('101')).toBeNull()
    expect(window.localStorage.getItem('collavre_chat_drafts_9')).not.toContain('101')
  })

  test('set with blank text on a missing entry is a no-op (no write)', () => {
    drafts.set('101', '')
    expect(window.localStorage.getItem('collavre_chat_drafts_9')).toBeNull()
  })

  test('clear removes a single draft', () => {
    drafts.set('101', 'a')
    drafts.set('102', 'b')
    drafts.clear('101')
    expect(drafts.get('101')).toBeNull()
    expect(drafts.get('102')).toBe('b')
  })

  test('clearAll removes the storage key', () => {
    drafts.set('101', 'a')
    drafts.clearAll()
    expect(window.localStorage.getItem('collavre_chat_drafts_9')).toBeNull()
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

  test('prunes entries older than the 7-day TTL on load', () => {
    const eightDaysAgo = Date.now() - 8 * 24 * 60 * 60 * 1000
    window.localStorage.setItem(
      'collavre_chat_drafts_9',
      JSON.stringify({
        old: { text: 'stale', updatedAt: eightDaysAgo },
        fresh: { text: 'recent', updatedAt: Date.now() },
      }),
    )
    expect(drafts.get('old')).toBeNull()
    expect(drafts.get('fresh')).toBe('recent')
  })

  test('survives corrupted stored JSON', () => {
    window.localStorage.setItem('collavre_chat_drafts_9', '{not json')
    expect(drafts.get('101')).toBeNull()
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
})
