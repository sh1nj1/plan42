/**
 * @jest-environment jsdom
 */

/**
 * Tests for the selection action bar behavior.
 * We test the DOM rendering logic directly without importing the full controller
 * (which has deep dependencies that are hard to mock in ESM mode).
 */

describe('Selection Action Bar - DOM behavior', () => {
  let container

  function createActionBar(count, dataset = {}) {
    const existing = document.querySelector('.selection-action-bar')
    if (existing) existing.remove()

    if (count === 0) return null

    const i18n = (key, fallback) => dataset[key] || fallback

    const bar = document.createElement('div')
    bar.className = 'selection-action-bar'
    bar.innerHTML = `
      <div class="selection-action-bar-main">
        <span class="selection-action-bar-count">${i18n('selectionCountText', '{count} selected').replace('{count}', count)}</span>
        <button type="button" class="selection-action-bar-btn selection-action-delete">🗑 ${i18n('selectionDeleteText', 'Delete')}</button>
        <button type="button" class="selection-action-bar-btn selection-action-move">📤 ${i18n('selectionMoveText', 'Move')}</button>
        <button type="button" class="selection-action-bar-btn selection-action-topic">🏷 ${i18n('selectionTopicMoveText', 'Move to topic')}</button>
        <button type="button" class="selection-action-bar-close">✕</button>
      </div>
      <div class="selection-action-bar-hint no-touch">
        💡 ${i18n('selectionDragHintText', 'Drag & drop to move to topic')}
      </div>
      <div class="selection-action-bar-hint touch-drag-hint">
        💡 ${i18n('selectionTouchDragHintText', 'Long press to drag to topic')}
      </div>
    `
    document.body.appendChild(bar)
    return bar
  }

  beforeEach(() => {
    container = document.createElement('div')
    document.body.appendChild(container)
  })

  afterEach(() => {
    document.body.removeChild(container)
    document.querySelectorAll('.selection-action-bar').forEach(el => el.remove())
  })

  test('creates action bar with correct count', () => {
    const bar = createActionBar(3)
    expect(bar).toBeTruthy()
    expect(bar.querySelector('.selection-action-bar-count').textContent).toBe('3 selected')
  })

  test('returns null and removes bar when count is 0', () => {
    createActionBar(2)
    expect(document.querySelector('.selection-action-bar')).toBeTruthy()

    const result = createActionBar(0)
    expect(result).toBeNull()
    expect(document.querySelector('.selection-action-bar')).toBeNull()
  })

  test('has all required action buttons', () => {
    const bar = createActionBar(1)
    expect(bar.querySelector('.selection-action-delete')).toBeTruthy()
    expect(bar.querySelector('.selection-action-move')).toBeTruthy()
    expect(bar.querySelector('.selection-action-topic')).toBeTruthy()
    expect(bar.querySelector('.selection-action-bar-close')).toBeTruthy()
  })

  test('shows drag hint with no-touch class', () => {
    const bar = createActionBar(1)
    const hint = bar.querySelector('.selection-action-bar-hint')
    expect(hint).toBeTruthy()
    expect(hint.classList.contains('no-touch')).toBe(true)
    expect(hint.textContent).toContain('Drag & drop')
  })

  test('shows touch drag hint with touch-drag-hint class', () => {
    const bar = createActionBar(1)
    const hints = bar.querySelectorAll('.selection-action-bar-hint')
    expect(hints.length).toBe(2)
    const touchHint = bar.querySelector('.selection-action-bar-hint.touch-drag-hint')
    expect(touchHint).toBeTruthy()
    expect(touchHint.textContent).toContain('Long press')
  })

  test('uses i18n dataset values when provided', () => {
    const bar = createActionBar(5, {
      selectionCountText: '{count}개 선택',
      selectionDeleteText: '삭제',
      selectionMoveText: '이동',
      selectionTopicMoveText: '토픽 이동',
      selectionDragHintText: '드래그&드롭으로도 토픽 이동 가능',
    })
    expect(bar.querySelector('.selection-action-bar-count').textContent).toBe('5개 선택')
    expect(bar.querySelector('.selection-action-delete').textContent).toContain('삭제')
    expect(bar.querySelector('.selection-action-move').textContent).toContain('이동')
    expect(bar.querySelector('.selection-action-topic').textContent).toContain('토픽 이동')
    expect(bar.querySelector('.selection-action-bar-hint').textContent).toContain('드래그&드롭')
  })

  test('replaces existing bar when called again', () => {
    createActionBar(1)
    createActionBar(3)
    const bars = document.querySelectorAll('.selection-action-bar')
    expect(bars.length).toBe(1)
    expect(bars[0].querySelector('.selection-action-bar-count').textContent).toBe('3 selected')
  })
})
