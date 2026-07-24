/**
 * @jest-environment jsdom
 */
import { ChatNavigationHistory } from '../chat_history'

describe('ChatNavigationHistory', () => {
  let history

  beforeEach(() => {
    window.sessionStorage.clear()
    history = new ChatNavigationHistory()
  })

  test('starts empty', () => {
    expect(history.current()).toBeNull()
    expect(history.canNavigate()).toBe(false)
    expect(history.recentList()).toEqual([])
  })

  test('push adds entries', () => {
    history.push({ creativeId: '1', snippet: 'A' })
    expect(history.current().creativeId).toBe('1')

    history.push({ creativeId: '2', snippet: 'B' })
    expect(history.current().creativeId).toBe('2')
    expect(history.entries.length).toBe(2)
  })

  test('push deduplicates by creativeId', () => {
    history.push({ creativeId: '1', snippet: 'A' })
    history.push({ creativeId: '2', snippet: 'B' })
    history.push({ creativeId: '1', snippet: 'A updated' })

    expect(history.entries.length).toBe(2)
    expect(history.current().creativeId).toBe('1')
    expect(history.current().snippet).toBe('A updated')
  })

  test('revisit reorders entry to reflect visit order', () => {
    history.push({ creativeId: '1', snippet: 'A' })
    history.push({ creativeId: '2', snippet: 'B' })
    history.push({ creativeId: '3', snippet: 'C' })
    history.push({ creativeId: '4', snippet: 'D' })
    // entries: [A, B, C, D], cursor at D (index 3)

    history.push({ creativeId: '2', snippet: 'B' })
    // B should move after D: [A, C, D, B], cursor at B (index 3)
    expect(history.entries.map(e => e.creativeId)).toEqual(['1', '3', '4', '2'])
    expect(history.current().creativeId).toBe('2')

    // prev should go back to D (where we came from)
    expect(history.prev().creativeId).toBe('4')
    expect(history.prev().creativeId).toBe('3')
    expect(history.prev().creativeId).toBe('1')
    // wraps around
    expect(history.prev().creativeId).toBe('2')
  })

  test('revisit current entry does not reorder', () => {
    history.push({ creativeId: '1', snippet: 'A' })
    history.push({ creativeId: '2', snippet: 'B' })
    history.push({ creativeId: '3', snippet: 'C' })

    history.push({ creativeId: '3', snippet: 'C updated' })
    expect(history.entries.map(e => e.creativeId)).toEqual(['1', '2', '3'])
    expect(history.current().creativeId).toBe('3')
    expect(history.current().snippet).toBe('C updated')
  })

  test('prev cycles backward', () => {
    history.push({ creativeId: '1', snippet: 'A' })
    history.push({ creativeId: '2', snippet: 'B' })
    history.push({ creativeId: '3', snippet: 'C' })
    // currentIndex = 2 (C)

    expect(history.prev().creativeId).toBe('2') // B
    expect(history.prev().creativeId).toBe('1') // A
    expect(history.prev().creativeId).toBe('3') // C — wraps around!
    expect(history.prev().creativeId).toBe('2') // B — keeps cycling
  })

  test('next cycles forward', () => {
    history.push({ creativeId: '1', snippet: 'A' })
    history.push({ creativeId: '2', snippet: 'B' })
    history.push({ creativeId: '3', snippet: 'C' })
    // currentIndex = 2 (C)

    expect(history.next().creativeId).toBe('1') // A — wraps around!
    expect(history.next().creativeId).toBe('2') // B
    expect(history.next().creativeId).toBe('3') // C
    expect(history.next().creativeId).toBe('1') // A — keeps cycling
  })

  test('prev returns null when only one entry', () => {
    history.push({ creativeId: '1', snippet: 'A' })
    expect(history.prev()).toBeNull()
  })

  test('next returns null when only one entry', () => {
    history.push({ creativeId: '1', snippet: 'A' })
    expect(history.next()).toBeNull()
  })

  test('canNavigate requires at least 2 entries', () => {
    expect(history.canNavigate()).toBe(false)
    history.push({ creativeId: '1', snippet: 'A' })
    expect(history.canNavigate()).toBe(false)
    history.push({ creativeId: '2', snippet: 'B' })
    expect(history.canNavigate()).toBe(true)
  })

  test('recentList returns all entries with isCurrent', () => {
    history.push({ creativeId: '1', snippet: 'A' })
    history.push({ creativeId: '2', snippet: 'B' })
    history.push({ creativeId: '3', snippet: 'C' })

    const list = history.recentList()
    expect(list.length).toBe(3)
    expect(list[0].creativeId).toBe('1')
    expect(list[0].isCurrent).toBe(false)
    expect(list[2].creativeId).toBe('3')
    expect(list[2].isCurrent).toBe(true)
  })

  test('goTo navigates to specific index', () => {
    history.push({ creativeId: '1', snippet: 'A' })
    history.push({ creativeId: '2', snippet: 'B' })
    history.push({ creativeId: '3', snippet: 'C' })

    const result = history.goTo(0)
    expect(result.creativeId).toBe('1')
    expect(history.current().creativeId).toBe('1')
  })

  test('goTo returns null for current index', () => {
    history.push({ creativeId: '1', snippet: 'A' })
    history.push({ creativeId: '2', snippet: 'B' })
    expect(history.goTo(1)).toBeNull() // already at index 1
  })

  test('remove deletes entry and adjusts index', () => {
    history.push({ creativeId: '1', snippet: 'A' })
    history.push({ creativeId: '2', snippet: 'B' })
    history.push({ creativeId: '3', snippet: 'C' })

    history.remove('2')
    expect(history.entries.length).toBe(2)
    expect(history.entries[0].creativeId).toBe('1')
    expect(history.entries[1].creativeId).toBe('3')
    // currentIndex was 2 (C), after removing index 1, should be 1 (still C)
    expect(history.current().creativeId).toBe('3')
  })

  test('persists to sessionStorage', () => {
    history.push({ creativeId: '1', snippet: 'A' })
    history.push({ creativeId: '2', snippet: 'B' })

    const restored = new ChatNavigationHistory()
    expect(restored.entries.length).toBe(2)
    expect(restored.current().creativeId).toBe('2')
  })

  test('clear resets everything', () => {
    history.push({ creativeId: '1', snippet: 'A' })
    history.push({ creativeId: '2', snippet: 'B' })
    history.clear()
    expect(history.entries.length).toBe(0)
    expect(history.current()).toBeNull()
  })

  test('ignores push with no creativeId', () => {
    history.push({})
    history.push(null)
    expect(history.entries.length).toBe(0)
  })

  test('respects max size', () => {
    for (let i = 0; i < 25; i++) {
      history.push({ creativeId: String(i), snippet: `Item ${i}` })
    }
    expect(history.entries.length).toBe(20)
  })
})
