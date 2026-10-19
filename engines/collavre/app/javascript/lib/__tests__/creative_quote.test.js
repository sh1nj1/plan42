/**
 * @jest-environment jsdom
 */
import { jest } from '@jest/globals'
import {
  commonAncestorCreativeId,
  creativeQuoteTarget,
  creativeLabel,
  selectionPopupSupported,
  quoteFromSelection,
  scrollToCreativeRow,
} from '../creative_quote'

// jsdom has no CSS.escape.
if (!globalThis.CSS?.escape) {
  globalThis.CSS = { ...(globalThis.CSS || {}), escape: (value) => String(value).replace(/["\\]/g, '\\$&') }
}

// 1
// ├─ 2
// │  └─ 4
// └─ 3
// 9 (separate root)
const TREE = `
  <creative-tree-row creative-id="1"><div class="creative-title-content">Title   of
    the doc</div></creative-tree-row>
  <creative-tree-row creative-id="2" parent-id="1"><div class="creative-content">Second <b>bold</b></div></creative-tree-row>
  <creative-tree-row creative-id="4" parent-id="2"><div class="creative-content">Fourth</div>
    <button class="row-btn">Btn</button>
    <div class="creative-progress-area">50%</div>
  </creative-tree-row>
  <creative-tree-row creative-id="3" parent-id="1"><div class="creative-content">Third</div></creative-tree-row>
  <creative-tree-row creative-id="9"><div class="creative-content">Elsewhere</div></creative-tree-row>
  <div class="outside-rows">Not a row body</div>
  <form id="inline-edit-form"><div class="editing">Editing text</div></form>
`

let root

beforeEach(() => {
  root = document.createElement('div')
  root.innerHTML = TREE
  document.body.appendChild(root)
})

afterEach(() => {
  window.getSelection().removeAllRanges()
  document.body.innerHTML = ''
})

const row = (id) => root.querySelector(`[creative-id="${id}"]`)

function select(startNode, startOffset, endNode, endOffset) {
  const range = document.createRange()
  range.setStart(startNode, startOffset)
  range.setEnd(endNode, endOffset)
  const selection = window.getSelection()
  selection.removeAllRanges()
  selection.addRange(range)
  return selection
}

function selectContents(node) {
  const range = document.createRange()
  range.selectNodeContents(node)
  const selection = window.getSelection()
  selection.removeAllRanges()
  selection.addRange(range)
  return selection
}

describe('commonAncestorCreativeId', () => {
  test('returns null for no ids', () => {
    expect(commonAncestorCreativeId([], root)).toBeNull()
    expect(commonAncestorCreativeId([null, undefined, ''], root)).toBeNull()
  })

  test('returns the single id as a string, deduplicating', () => {
    expect(commonAncestorCreativeId([4, '4', 4], root)).toBe('4')
  })

  test('finds the nearest shared ancestor', () => {
    expect(commonAncestorCreativeId(['4', '3'], root)).toBe('1')
    expect(commonAncestorCreativeId(['4', '2'], root)).toBe('2')
  })

  test('falls back to the first id when nothing is shared', () => {
    expect(commonAncestorCreativeId(['4', '9'], root)).toBe('4')
  })

  test('stops at rows missing from the page', () => {
    expect(commonAncestorCreativeId(['404', '4'], root)).toBe('404')
  })

  test('reads the parentId property when the attribute is absent', () => {
    const r = row('3')
    r.removeAttribute('parent-id')
    r.parentId = 2
    expect(commonAncestorCreativeId(['3', '4'], root)).toBe('2')
  })

  test('survives a parent cycle', () => {
    row('1').setAttribute('parent-id', '4')
    expect(commonAncestorCreativeId(['3', '9'], root)).toBe('3')
  })

  test('defaults to the document root', () => {
    expect(commonAncestorCreativeId(['4', '3'])).toBe('1')
  })
})

describe('creativeQuoteTarget', () => {
  test('returns null without quotes', () => {
    expect(creativeQuoteTarget(null, root)).toBeNull()
    expect(creativeQuoteTarget([], root)).toBeNull()
  })

  test('targets the common ancestor with the first quote text', () => {
    expect(creativeQuoteTarget([
      { creativeId: '4', text: 'first' },
      { creativeId: '3', text: 'second' },
    ], root)).toEqual({ creativeId: '1', text: 'first' })
  })

  test('defaults to the document root', () => {
    expect(creativeQuoteTarget([{ creativeId: '2', text: 't' }])).toEqual({ creativeId: '2', text: 't' })
  })
})

describe('creativeLabel', () => {
  test('collapses whitespace in the row body', () => {
    expect(creativeLabel(row('1'))).toBe('Title of the doc')
  })

  test('truncates long text with an ellipsis', () => {
    row('3').querySelector('.creative-content').textContent = 'x'.repeat(60)
    const label = creativeLabel(row('3'))
    expect(label).toHaveLength(40)
    expect(label.endsWith('…')).toBe(true)
  })

  test('is empty for a missing row or body', () => {
    expect(creativeLabel(null)).toBe('')
    expect(creativeLabel(document.createElement('div'))).toBe('')
  })
})

describe('selectionPopupSupported', () => {
  test('false without matchMedia', () => {
    expect(selectionPopupSupported({})).toBe(false)
  })

  test('follows the hover/pointer media query', () => {
    const matchMedia = jest.fn(() => ({ matches: true }))
    expect(selectionPopupSupported({ matchMedia })).toBe(true)
    expect(matchMedia).toHaveBeenCalledWith('(hover: hover) and (pointer: fine)')
    expect(selectionPopupSupported({ matchMedia: () => ({ matches: false }) })).toBe(false)
  })

  test('defaults to window', () => {
    const original = window.matchMedia
    window.matchMedia = () => ({ matches: true })
    try {
      expect(selectionPopupSupported()).toBe(true)
    } finally {
      window.matchMedia = original
    }
  })
})

describe('quoteFromSelection', () => {
  test('ignores missing, collapsed or empty selections', () => {
    expect(quoteFromSelection(null, root)).toBeNull()
    expect(quoteFromSelection({ isCollapsed: true, rangeCount: 1 }, root)).toBeNull()
    expect(quoteFromSelection({ isCollapsed: false, rangeCount: 0 }, root)).toBeNull()
    expect(quoteFromSelection({ isCollapsed: false, rangeCount: 1, toString: () => '   ' }, root)).toBeNull()
  })

  test('quotes text inside a single row body (text node container)', () => {
    const text = row('3').querySelector('.creative-content').firstChild
    const selection = select(text, 0, text, 3)
    expect(quoteFromSelection(selection, root)).toEqual({ creativeId: '3', text: 'Thi', label: 'Third' })
  })

  test('quotes with an element container', () => {
    const selection = selectContents(row('2').querySelector('.creative-content'))
    expect(quoteFromSelection(selection, root)).toEqual({ creativeId: '2', text: 'Second bold', label: 'Second bold' })
  })

  test('a selection across rows targets their common ancestor', () => {
    const start = row('4').querySelector('.creative-content').firstChild
    const end = row('3').querySelector('.creative-content').firstChild
    const quote = quoteFromSelection(select(start, 0, end, 5), root)
    // Rows 4 (under 2) and 3 are intersected; they meet at 1.
    expect(quote).toMatchObject({ creativeId: '1', label: 'Title of the doc' })
    expect(quote.text.startsWith('Fourth')).toBe(true)
  })

  test('rejects selections outside the root', () => {
    const outside = document.createElement('p')
    outside.textContent = 'outside text'
    document.body.appendChild(outside)
    expect(quoteFromSelection(selectContents(outside), root)).toBeNull()
  })

  test('rejects selections in the inline editor', () => {
    expect(quoteFromSelection(selectContents(root.querySelector('.editing')), root)).toBeNull()
  })

  test('rejects selections on non-text UI', () => {
    expect(quoteFromSelection(selectContents(root.querySelector('.row-btn')), root)).toBeNull()
    expect(quoteFromSelection(selectContents(root.querySelector('.creative-progress-area')), root)).toBeNull()
  })

  test('rejects selections outside any row body', () => {
    expect(quoteFromSelection(selectContents(root.querySelector('.outside-rows')), root)).toBeNull()
  })

  test('rejects rows without a creative id', () => {
    const bare = document.createElement('creative-tree-row')
    bare.innerHTML = '<div class="creative-content">No id</div>'
    root.appendChild(bare)
    expect(quoteFromSelection(selectContents(bare.querySelector('.creative-content')), root)).toBeNull()
  })

  test('uses the creativeId property and falls back to the intersected row for the label', () => {
    const propRow = document.createElement('creative-tree-row')
    propRow.creativeId = 77
    propRow.innerHTML = '<div class="creative-content">Prop row</div>'
    root.appendChild(propRow)
    expect(quoteFromSelection(selectContents(propRow.querySelector('.creative-content')), root))
      .toEqual({ creativeId: '77', text: 'Prop row', label: 'Prop row' })
  })
})

describe('scrollToCreativeRow', () => {
  test('returns false when the row is not on the page', () => {
    expect(scrollToCreativeRow('404', root)).toBe(false)
    expect(scrollToCreativeRow(null, root)).toBe(false)
  })

  test('scrolls to and briefly highlights the row', () => {
    jest.useFakeTimers()
    try {
      const r = row('3')
      r.scrollIntoView = jest.fn()
      expect(scrollToCreativeRow(3)).toBe(true)
      expect(r.scrollIntoView).toHaveBeenCalledWith({ behavior: 'smooth', block: 'center' })
      expect(r.classList.contains('creative-quote-highlight')).toBe(true)
      jest.advanceTimersByTime(2000)
      expect(r.classList.contains('creative-quote-highlight')).toBe(false)
    } finally {
      jest.useRealTimers()
    }
  })
})
