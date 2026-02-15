import { wrapHtmlInCodeBlocks } from '../html_code_block_wrapper'

describe('wrapHtmlInCodeBlocks', () => {
  // --- No change cases ---

  test('returns unchanged for null/undefined/empty', () => {
    expect(wrapHtmlInCodeBlocks(null)).toEqual({ changed: false, result: null })
    expect(wrapHtmlInCodeBlocks(undefined)).toEqual({ changed: false, result: undefined })
    expect(wrapHtmlInCodeBlocks('')).toEqual({ changed: false, result: '' })
  })

  test('returns unchanged for plain text', () => {
    const text = 'Hello world, no HTML here'
    expect(wrapHtmlInCodeBlocks(text)).toEqual({ changed: false, result: text })
  })

  test('returns unchanged for text with angle brackets but no tags', () => {
    expect(wrapHtmlInCodeBlocks('5 > 3 and 2 < 4')).toEqual({
      changed: false,
      result: '5 > 3 and 2 < 4',
    })
  })

  test('returns unchanged for already code-blocked content', () => {
    const text = '```html\n<div>hello</div>\n```'
    expect(wrapHtmlInCodeBlocks(text)).toEqual({ changed: false, result: text })
  })

  test('returns unchanged for code block with leading whitespace', () => {
    const text = '  ```\n<div>hello</div>\n```'
    expect(wrapHtmlInCodeBlocks(text)).toEqual({ changed: false, result: text })
  })

  // --- Single HTML block ---

  test('wraps a single div', () => {
    const { changed, result } = wrapHtmlInCodeBlocks('<div>hello</div>')
    expect(changed).toBe(true)
    expect(result).toBe('```html\n<div>hello</div>\n```')
  })

  test('wraps a div with attributes', () => {
    const { changed, result } = wrapHtmlInCodeBlocks('<div class="test" id="foo">content</div>')
    expect(changed).toBe(true)
    expect(result).toBe('```html\n<div class="test" id="foo">content</div>\n```')
  })

  test('wraps nested HTML', () => {
    const html = '<div><p>hello</p><span>world</span></div>'
    const { changed, result } = wrapHtmlInCodeBlocks(html)
    expect(changed).toBe(true)
    expect(result).toBe('```html\n' + html + '\n```')
  })

  test('wraps self-closing tag', () => {
    const { changed, result } = wrapHtmlInCodeBlocks('<br/>')
    expect(changed).toBe(true)
    expect(result).toBe('```html\n<br/>\n```')
  })

  test('wraps self-closing tag with space', () => {
    const { changed, result } = wrapHtmlInCodeBlocks('<img src="test.png" />')
    expect(changed).toBe(true)
    expect(result).toBe('```html\n<img src="test.png" />\n```')
  })

  // --- HTML with surrounding text ---

  test('wraps HTML with text before', () => {
    const { changed, result } = wrapHtmlInCodeBlocks('여기 봐봐 <div>hello</div>')
    expect(changed).toBe(true)
    expect(result).toBe('여기 봐봐 \n\n```html\n<div>hello</div>\n```')
  })

  test('wraps HTML with text after', () => {
    const { changed, result } = wrapHtmlInCodeBlocks('<div>hello</div> 이거 뭐야?')
    expect(changed).toBe(true)
    expect(result).toBe('```html\n<div>hello</div>\n```\n\n 이거 뭐야?')
  })

  test('wraps HTML with text before and after', () => {
    const { changed, result } = wrapHtmlInCodeBlocks('여기 봐봐 <div>hello</div> 이거 뭐야?')
    expect(changed).toBe(true)
    expect(result).toBe('여기 봐봐 \n\n```html\n<div>hello</div>\n```\n\n 이거 뭐야?')
  })

  // --- Multiple HTML blocks ---

  test('wraps multiple separate HTML blocks', () => {
    const { changed, result } = wrapHtmlInCodeBlocks('<div>first</div> text <span>second</span>')
    expect(changed).toBe(true)
    expect(result).toBe('```html\n<div>first</div>\n```\n\n text \n\n```html\n<span>second</span>\n```')
  })

  // --- Complex real-world HTML ---

  test('wraps complex HTML with attributes and nesting', () => {
    const html = '<div id="llm-model-suggestions" class="common-popup mention-popup" style="display: none;"><ul class="common-popup-list"><li class="common-popup-item"><div class="mention-item">gemini-2.5-flash</div></li></ul></div>'
    const { changed, result } = wrapHtmlInCodeBlocks(html)
    expect(changed).toBe(true)
    expect(result).toBe('```html\n' + html + '\n```')
  })

  test('wraps complex HTML with surrounding text', () => {
    const html = '<div id="test" class="popup" style="display: none;"><ul><li>item</li></ul></div>'
    const input = '이 코드를 봐줘 ' + html + ' 이게 맞아?'
    const { changed, result } = wrapHtmlInCodeBlocks(input)
    expect(changed).toBe(true)
    expect(result).toBe('이 코드를 봐줘 \n\n```html\n' + html + '\n```\n\n 이게 맞아?')
  })

  // --- Multiline HTML ---

  test('wraps multiline HTML', () => {
    const html = '<div>\n  <p>hello</p>\n  <p>world</p>\n</div>'
    const { changed, result } = wrapHtmlInCodeBlocks(html)
    expect(changed).toBe(true)
    expect(result).toBe('```html\n' + html + '\n```')
  })

  // --- Edge cases ---

  test('handles single unclosed tag (no match)', () => {
    const text = '<div>hello but no closing tag'
    expect(wrapHtmlInCodeBlocks(text)).toEqual({ changed: false, result: text })
  })

  test('handles mismatched tags (no match)', () => {
    const text = '<div>hello</span>'
    expect(wrapHtmlInCodeBlocks(text)).toEqual({ changed: false, result: text })
  })

  test('handles HTML-like content in markdown', () => {
    const { changed, result } = wrapHtmlInCodeBlocks('<b>bold text</b>')
    expect(changed).toBe(true)
    expect(result).toBe('```html\n<b>bold text</b>\n```')
  })

  test('handles table HTML', () => {
    const html = '<table><tr><td>cell</td></tr></table>'
    const { changed, result } = wrapHtmlInCodeBlocks(html)
    expect(changed).toBe(true)
    expect(result).toBe('```html\n' + html + '\n```')
  })

  test('handles input self-closing tag', () => {
    const { changed, result } = wrapHtmlInCodeBlocks('<input type="text" />')
    expect(changed).toBe(true)
    expect(result).toBe('```html\n<input type="text" />\n```')
  })

  test('does not wrap markdown syntax', () => {
    const text = '# heading\n\n**bold** and *italic*'
    expect(wrapHtmlInCodeBlocks(text)).toEqual({ changed: false, result: text })
  })

  test('does not wrap template literals with angle brackets', () => {
    const text = 'array.filter(x => x > 0)'
    expect(wrapHtmlInCodeBlocks(text)).toEqual({ changed: false, result: text })
  })

  // --- Failure scenario: typing text then pasting HTML ---

  test('text followed by HTML renders as proper markdown code block', () => {
    const { changed, result } = wrapHtmlInCodeBlocks('test <html><h1>hello</h1></html>')
    expect(changed).toBe(true)
    // Must have blank line before code fence for marked to parse correctly
    expect(result).toBe('test \n\n```html\n<html><h1>hello</h1></html>\n```')
    expect(result).toContain('\n\n```html')
  })

  // --- Double-wrap prevention ---

  test('does not double-wrap HTML inside existing code blocks', () => {
    const input = '"\n```html\n<button type="button" class="popup-close-btn">×</button>\n```\n"'
    const { changed } = wrapHtmlInCodeBlocks(input)
    expect(changed).toBe(false)
  })

  test('does not wrap HTML inside code blocks but wraps HTML outside', () => {
    const input = 'before\n```html\n<div>inside</div>\n```\nafter <span>outside</span> end'
    const { changed, result } = wrapHtmlInCodeBlocks(input)
    expect(changed).toBe(true)
    expect(result).toContain('```html\n<div>inside</div>\n```')
    expect(result).toContain('```html\n<span>outside</span>\n```')
    // The inside div should NOT be double-wrapped
    expect(result).not.toContain('```html\n```html')
  })

  test('mixed text with code block containing HTML is not double-wrapped', () => {
    const input = 'some text\n```\n<button>click</button>\n```\nmore text'
    const { changed } = wrapHtmlInCodeBlocks(input)
    expect(changed).toBe(false)
  })

  test('text starting with quote then code block is not double-wrapped', () => {
    const input = '"\n```html\n<button id="close-slack-modal" class="popup-close-btn">×</button>\n```\n"'
    const { changed } = wrapHtmlInCodeBlocks(input)
    expect(changed).toBe(false)
  })
})
