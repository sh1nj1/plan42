import { ChatNavigationHistory } from '../chat_history.js'

describe('ChatNavigationHistory', () => {
  let history

  beforeEach(() => {
    window.sessionStorage.clear()
    history = new ChatNavigationHistory()
  })

  const entry = (id) => ({ creativeId: String(id), snippet: `Creative ${id}`, canComment: true })

  test('starts empty', () => {
    expect(history.canGoBack()).toBe(false)
    expect(history.canGoForward()).toBe(false)
    expect(history.current).toBeNull()
  })

  test('push sets current', () => {
    history.push(entry(1))
    expect(history.current.creativeId).toBe('1')
    expect(history.canGoBack()).toBe(false)
  })

  test('push multiple builds back stack', () => {
    history.push(entry(1))
    history.push(entry(2))
    history.push(entry(3))
    expect(history.current.creativeId).toBe('3')
    expect(history.canGoBack()).toBe(true)
    expect(history.canGoForward()).toBe(false)
  })

  test('back returns previous entry', () => {
    history.push(entry(1))
    history.push(entry(2))
    const result = history.back()
    expect(result.creativeId).toBe('1')
    expect(history.current.creativeId).toBe('1')
    expect(history.canGoForward()).toBe(true)
  })

  test('forward returns next entry', () => {
    history.push(entry(1))
    history.push(entry(2))
    history.back()
    const result = history.forward()
    expect(result.creativeId).toBe('2')
    expect(history.canGoForward()).toBe(false)
  })

  test('push after back clears forward stack', () => {
    history.push(entry(1))
    history.push(entry(2))
    history.push(entry(3))
    history.back()
    history.back()
    // Now at 1, forward has [2, 3]
    history.push(entry(4))
    expect(history.current.creativeId).toBe('4')
    expect(history.canGoForward()).toBe(false)
  })

  test('duplicate push updates metadata only', () => {
    history.push(entry(1))
    history.push({ creativeId: '1', snippet: 'Updated', canComment: false })
    expect(history.current.snippet).toBe('Updated')
    expect(history.canGoBack()).toBe(false) // no new entry pushed
  })

  test('back on empty returns null', () => {
    expect(history.back()).toBeNull()
  })

  test('forward on empty returns null', () => {
    expect(history.forward()).toBeNull()
  })

  test('recentList returns chronological list with current flag', () => {
    history.push(entry(1))
    history.push(entry(2))
    history.push(entry(3))
    history.back() // now at 2, forward has [3]

    const list = history.recentList()
    expect(list).toHaveLength(3)
    expect(list[0].creativeId).toBe('1')
    expect(list[0].isCurrent).toBe(false)
    expect(list[1].creativeId).toBe('2')
    expect(list[1].isCurrent).toBe(true)
    expect(list[2].creativeId).toBe('3')
    expect(list[2].isCurrent).toBe(false)
  })

  test('goTo navigates to specific entry', () => {
    history.push(entry(1))
    history.push(entry(2))
    history.push(entry(3))

    const result = history.goTo(0) // go to entry(1)
    expect(result.creativeId).toBe('1')
    expect(history.current.creativeId).toBe('1')
    expect(history.canGoForward()).toBe(true)
  })

  test('persists to sessionStorage', () => {
    history.push(entry(1))
    history.push(entry(2))

    const history2 = new ChatNavigationHistory()
    expect(history2.current.creativeId).toBe('2')
    expect(history2.canGoBack()).toBe(true)
  })

  test('clear resets everything', () => {
    history.push(entry(1))
    history.push(entry(2))
    history.clear()
    expect(history.current).toBeNull()
    expect(history.canGoBack()).toBe(false)
    expect(history.canGoForward()).toBe(false)
  })

  test('push with null entry is ignored', () => {
    history.push(null)
    expect(history.current).toBeNull()
  })

  test('push with missing creativeId is ignored', () => {
    history.push({ snippet: 'no id' })
    expect(history.current).toBeNull()
  })

  test('max stack size is enforced', () => {
    for (let i = 0; i < 25; i++) {
      history.push(entry(i))
    }
    expect(history.backStack.length).toBeLessThanOrEqual(20)
  })
})
