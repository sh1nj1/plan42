import { sanitizeDescriptionHtml } from '../sanitize_description'

describe('sanitizeDescriptionHtml', () => {
  test('keeps a YouTube embed iframe the server generated', () => {
    const html =
      '<p><iframe src="https://www.youtube.com/embed/dQw4w9WgXcQ" ' +
      'title="YouTube video player" frameborder="0" ' +
      'allow="autoplay; encrypted-media" allowfullscreen></iframe></p>'
    const out = sanitizeDescriptionHtml(html)
    expect(out).toContain('<iframe')
    expect(out).toContain('youtube.com/embed/dQw4w9WgXcQ')
    expect(out).toContain('allowfullscreen')
  })

  test('keeps a youtube-nocookie embed iframe', () => {
    const html =
      '<iframe src="https://www.youtube-nocookie.com/embed/abc123"></iframe>'
    expect(sanitizeDescriptionHtml(html)).toContain('<iframe')
  })

  test('strips a non-YouTube iframe (XSS protection)', () => {
    const html = '<p><iframe src="https://evil.example.com/x"></iframe></p>'
    const out = sanitizeDescriptionHtml(html)
    expect(out).not.toContain('<iframe')
    expect(out).not.toContain('evil.example.com')
  })

  test('strips an iframe pointing at the YouTube watch page (not /embed/)', () => {
    const html =
      '<iframe src="https://www.youtube.com/watch?v=dQw4w9WgXcQ"></iframe>'
    expect(sanitizeDescriptionHtml(html)).not.toContain('<iframe')
  })

  test('strips an iframe with a javascript: src', () => {
    const html = '<iframe src="javascript:alert(1)"></iframe>'
    expect(sanitizeDescriptionHtml(html)).not.toContain('<iframe')
  })

  test('strips script tags', () => {
    const out = sanitizeDescriptionHtml('<p>hi</p><script>alert(1)</script>')
    expect(out).toContain('hi')
    expect(out).not.toContain('<script')
  })

  test('preserves ordinary description markup', () => {
    const html = '<p>Hello <strong>world</strong></p>'
    expect(sanitizeDescriptionHtml(html)).toBe(html)
  })

  test('preserves server-rendered onboarding controls', () => {
    const html = '<button type="button" data-action="click->onboarding-card#open">Start</button>'
    const out = sanitizeDescriptionHtml(html)

    expect(out).toContain('<button')
    expect(out).toContain('data-action="click->onboarding-card#open"')
  })

  test('treats null/undefined as empty string', () => {
    expect(sanitizeDescriptionHtml(null)).toBe('')
    expect(sanitizeDescriptionHtml(undefined)).toBe('')
  })
})

describe('global iframe hook does not leak into the markdown/comment path', () => {
  test('renderMarkdown still strips YouTube iframes when the hook is loaded', async () => {
    // Importing the sanitizer registers a global DOMPurify uponSanitizeElement
    // hook. The comment/markdown sanitizer does not allow <iframe>, so even a
    // trusted YouTube iframe must still be stripped there.
    await import('../sanitize_description')
    const { renderMarkdown } = await import('../markdown')
    const out = renderMarkdown(
      '<p><iframe src="https://www.youtube.com/embed/abc"></iframe></p>'
    )
    expect(out).not.toContain('<iframe')
  })
})
