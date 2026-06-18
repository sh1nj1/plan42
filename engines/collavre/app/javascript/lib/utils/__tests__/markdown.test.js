import { renderMarkdown, renderCommentMarkdown, highlightCodeBlocks } from "../markdown"

// The renderers run with marked's `breaks: true` so a single newline becomes a
// <br> (GitHub/Slack style), matching the canonical markdown_source which stores
// consecutive rich-editor lines one-per-line instead of separated by a blank line.
describe("renderMarkdown hard breaks", () => {
  it("renders a single newline as <br> within one paragraph", () => {
    const html = renderMarkdown("abc\ndef")
    expect(html).toContain("<br")
    expect((html.match(/<p>/g) || []).length).toBe(1)
  })

  it("keeps a blank line as a paragraph break", () => {
    const html = renderMarkdown("abc\n\ndef")
    expect((html.match(/<p>/g) || []).length).toBe(2)
  })
})

describe("renderCommentMarkdown hard breaks", () => {
  it("renders a single newline in a comment as <br>", () => {
    expect(renderCommentMarkdown("line1\nline2")).toContain("<br")
  })
})

// Creative descriptions arrive as server-rendered `<pre lang="ruby"><code>raw</code></pre>`
// (commonmarker's inline highlighter is disabled). highlightCodeBlocks re-tokenizes
// them client-side with hljs so the rendered creative matches the editor palette.
describe("highlightCodeBlocks", () => {
  it("tokenizes a plain server code block using its lang attribute", () => {
    const el = document.createElement("div")
    el.innerHTML = '<pre lang="ruby"><code>puts :hi</code></pre>'
    highlightCodeBlocks(el)
    const code = el.querySelector("pre code")
    expect(code.classList.contains("hljs")).toBe(true)
    expect(code.querySelector(".hljs-keyword, .hljs-symbol, .hljs-string")).toBeTruthy()
  })

  it("re-highlights legacy blocks from textContent, dropping baked inline styles", () => {
    const el = document.createElement("div")
    // Simulates an old description whose stored HTML still carries syntect's
    // inline-styled spans and a dark <pre> background.
    el.innerHTML = '<pre lang="ruby" style="background-color:#2b303b;"><code>' +
      '<span style="color:#96b5b4;">puts </span><span style="color:#a3be8c;">:hi</span></code></pre>'
    highlightCodeBlocks(el)
    const pre = el.querySelector("pre")
    const code = el.querySelector("pre code")
    expect(pre.getAttribute("style")).toBeNull()
    expect(code.innerHTML).not.toContain("#2b303b")
    expect(code.textContent).toBe("puts :hi")
    expect(code.classList.contains("hljs")).toBe(true)
  })

  it("does not reinterpret code text as live HTML (no XSS via innerHTML)", () => {
    const el = document.createElement("div")
    // The decoded source text contains an XSS payload; after re-highlighting it
    // must remain inert text, never a live <img> element.
    el.innerHTML = '<pre lang="text"><code>&lt;img src=x onerror=alert(1)&gt;</code></pre>'
    highlightCodeBlocks(el)
    const code = el.querySelector("pre code")
    // The payload survives only as inert text, never as a live element.
    expect(code.querySelector("img")).toBeNull()
    expect(code.textContent).toBe("<img src=x onerror=alert(1)>")
  })

  it("is idempotent — already-highlighted blocks are skipped", () => {
    const el = document.createElement("div")
    el.innerHTML = '<pre lang="ruby"><code>puts :hi</code></pre>'
    highlightCodeBlocks(el)
    const first = el.querySelector("pre code").innerHTML
    highlightCodeBlocks(el)
    expect(el.querySelector("pre code").innerHTML).toBe(first)
  })
})
