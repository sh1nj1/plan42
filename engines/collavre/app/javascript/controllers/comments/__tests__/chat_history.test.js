import { ChatNavigationHistory } from '../../../lib/chat_history'

describe('ChatNavigationHistory', () => {
  let history

  beforeEach(() => {
    window.sessionStorage.clear()
    history = new ChatNavigationHistory()
  })

  test('starts empty', () => {
    expect(history.canGoBack()).toBe(false)
    expect(history.canGoForward()).toBe(false)
    expect(history.current).toBeNull()
    expect(history.recentList()).toEqual([])
  })

  test('push adds entries', () => {
    history.push({ creativeId: '1', snippet: 'A', canComment: true })
    expect(history.current.creativeId).toBe('1')
    expect(history.canGoBack()).toBe(false)

    history.push({ creativeId: '2', snippet: 'B', canComment: false })
    expect(history.current.creativeId).toBe('2')
    expect(history.canGoBack()).toBe(true)
  })

  test('push same creativeId updates metadata without adding to back stack', () => {
    history.push({ creativeId: '1', snippet: 'A', canComment: true })
    history.push({ creativeId: '1', snippet: 'A updated', canComment: false })
    expect(history.current.snippet).toBe('A updated')
    expect(history.current.canComment).toBe(false)
    expect(history.canGoBack()).toBe(false)
  })

  test('push clears forward stack', () => {
    history.push({ creativeId: '1', snippet: 'A' })
    history.push({ creativeId: '2', snippet: 'B' })
    history.back()
    expect(history.canGoForward()).toBe(true)

    history.push({ creativeId: '3', snippet: 'C' })
    expect(history.canGoForward()).toBe(false)
  })

  test('back and forward', () => {
    history.push({ creativeId: '1', snippet: 'A' })
    history.push({ creativeId: '2', snippet: 'B' })
    history.push({ creativeId: '3', snippet: 'C' })

    const b = history.back()
    expect(b.creativeId).toBe('2')
    expect(history.current.creativeId).toBe('2')
    expect(history.canGoForward()).toBe(true)

    const c = history.forward()
    expect(c.creativeId).toBe('3')
    expect(history.current.creativeId).toBe('3')
  })

  test('back returns null when at start', () => {
    history.push({ creativeId: '1', snippet: 'A' })
    expect(history.back()).toBeNull()
  })

  test('forward returns null when at end', () => {
    history.push({ creativeId: '1', snippet: 'A' })
    expect(history.forward()).toBeNull()
  })

  test('recentList returns all entries in chronological order', () => {
    history.push({ creativeId: '1', snippet: 'A' })
    history.push({ creativeId: '2', snippet: 'B' })
    history.push({ creativeId: '3', snippet: 'C' })
    history.back() // now on B, forward has C

    const list = history.recentList()
    expect(list.length).toBe(3)
    expect(list[0].creativeId).toBe('1')
    expect(list[0].isCurrent).toBe(false)
    expect(list[1].creativeId).toBe('2')
    expect(list[1].isCurrent).toBe(true)
    expect(list[2].creativeId).toBe('3')
    expect(list[2].isCurrent).toBe(false)
  })

  test('goTo navigates to specific entry', () => {
    history.push({ creativeId: '1', snippet: 'A' })
    history.push({ creativeId: '2', snippet: 'B' })
    history.push({ creativeId: '3', snippet: 'C' })

    const target = history.goTo(0) // go to first entry (A)
    expect(target.creativeId).toBe('1')
    expect(history.current.creativeId).toBe('1')
    expect(history.canGoBack()).toBe(false)
    expect(history.canGoForward()).toBe(true)
  })

  test('goTo returns null for current entry', () => {
    history.push({ creativeId: '1', snippet: 'A' })
    history.push({ creativeId: '2', snippet: 'B' })

    const list = history.recentList()
    const currentIdx = list.findIndex(e => e.isCurrent)
    expect(history.goTo(currentIdx)).toBeNull()
  })

  test('persists to sessionStorage', () => {
    history.push({ creativeId: '1', snippet: 'A' })
    history.push({ creativeId: '2', snippet: 'B' })

    const history2 = new ChatNavigationHistory()
    expect(history2.current.creativeId).toBe('2')
    expect(history2.canGoBack()).toBe(true)
  })

  test('clear resets everything', () => {
    history.push({ creativeId: '1', snippet: 'A' })
    history.push({ creativeId: '2', snippet: 'B' })
    history.clear()

    expect(history.current).toBeNull()
    expect(history.canGoBack()).toBe(false)
    expect(history.canGoForward()).toBe(false)
    expect(history.recentList()).toEqual([])
  })

  test('ignores push with no creativeId', () => {
    history.push({})
    history.push(null)
    expect(history.current).toBeNull()
  })

  test('respects max stack size', () => {
    for (let i = 0; i < 25; i++) {
      history.push({ creativeId: String(i), snippet: `Item ${i}` })
    }
    expect(history.backStack.length).toBe(20)
    expect(history.backStack[0].creativeId).toBe('4')
  })
})
