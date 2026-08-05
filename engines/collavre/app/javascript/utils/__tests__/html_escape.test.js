import { escapeHtmlText, escapeHtmlAttr } from '../html_escape'

describe('escapeHtmlText', () => {
  test('neutralizes tag delimiters so a payload cannot open an element', () => {
    const html = `<span>${escapeHtmlText('<img src=x onerror=alert(1)>')}</span>`
    const el = document.createElement('div')
    el.innerHTML = html
    expect(el.querySelector('img')).toBeNull()
    expect(el.textContent).toBe('<img src=x onerror=alert(1)>')
  })

  test('escapes the ampersand first so entities are not double-decoded', () => {
    // If & were escaped last, "&lt;" in the input would come back out as "<".
    const el = document.createElement('div')
    el.innerHTML = escapeHtmlText('&lt;script&gt;')
    expect(el.textContent).toBe('&lt;script&gt;')
  })

  test('renders null and undefined as empty, not as the words', () => {
    expect(escapeHtmlText(null)).toBe('')
    expect(escapeHtmlText(undefined)).toBe('')
  })
})

describe('escapeHtmlAttr', () => {
  test('neutralizes the quote that would end a double-quoted attribute', () => {
    // The break-out this exists to stop: a URL that closes src= and adds onerror=.
    const payload = 'x" onerror="window.__xss = true'
    const el = document.createElement('div')
    el.innerHTML = `<img src="${escapeHtmlAttr(payload)}">`
    const img = el.querySelector('img')
    expect(img.hasAttribute('onerror')).toBe(false)
    expect(img.getAttribute('src')).toBe(payload)
  })

  test('escapeHtmlText is NOT sufficient in attribute position', () => {
    // Pins why the two functions are separate rather than one shared escaper:
    // the text variant leaves the quote intact, so it would close the attribute.
    // Asserted on the escaped strings rather than by rendering the markup —
    // splicing a text-escaped value into an attribute is the defect itself, and
    // writing it here would be an incomplete-attribute-sanitization finding in
    // its own right. What breaking out actually does to the parser is covered
    // by the safe direction above.
    const payload = 'x" onerror="window.__xss = true'
    expect(escapeHtmlText(payload)).toContain('"')
    expect(escapeHtmlAttr(payload)).not.toContain('"')
  })

  test('renders null and undefined as empty, not as the words', () => {
    expect(escapeHtmlAttr(null)).toBe('')
    expect(escapeHtmlAttr(undefined)).toBe('')
  })
})
