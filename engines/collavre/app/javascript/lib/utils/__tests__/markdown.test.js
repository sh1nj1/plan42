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
// them client-side with the SAME Prism + `lexical-token-*` classes the editor uses,
// so the rendered creative matches edit mode token-for-token.
describe("highlightCodeBlocks", () => {
  it("tokenizes a plain server code block with lexical-token classes", () => {
    const el = document.createElement("div")
    el.innerHTML = '<pre lang="javascript"><code>const ok = true</code></pre>'
    highlightCodeBlocks(el)
    const code = el.querySelector("pre code")
    expect(code.querySelector(".lexical-token-keyword")).toBeTruthy() // const
    expect(code.querySelector(".lexical-token-boolean")).toBeTruthy() // true
  })

  it("honors an explicit ruby fence and tokenizes with the ruby grammar", () => {
    // The shared code_languages module registers the ruby grammar on the same
    // Prism instance the editor uses, so an explicit ```ruby fence is honored
    // instead of falling back to JavaScript.
    const el = document.createElement("div")
    el.innerHTML = '<pre lang="ruby"><code>def foo\n  nil\nend</code></pre>'
    highlightCodeBlocks(el)
    const code = el.querySelector("pre code")
    // `def`/`end` are Ruby keywords; JavaScript tokenization would not mark them.
    const keywords = Array.from(code.querySelectorAll(".lexical-token-keyword")).map((s) => s.textContent)
    expect(keywords).toContain("def")
    expect(keywords).toContain("end")
  })

  it("re-detects a Ruby block mislabeled as javascript (the default) and tokenizes as ruby", () => {
    // Reproduces the real bug: the editor baked ```javascript onto Ruby content.
    // The view re-detects the real language from the source so it matches edit mode.
    const el = document.createElement("div")
    el.innerHTML =
      '<pre lang="javascript"><code>' +
      '# frozen_string_literal: true\n' +
      'module CollavreCompat\n' +
      '  module_function\n' +
      '  def call(receiver, method_name, *args, **kwargs)\n' +
      '    receiver.public_send(method_name, *args, **kwargs)\n' +
      '  end\n' +
      'end</code></pre>'
    highlightCodeBlocks(el)
    const code = el.querySelector("pre code")
    const keywords = Array.from(code.querySelectorAll(".lexical-token-keyword")).map((s) => s.textContent)
    // Ruby `def`/`module`/`end` keywords — proof it tokenized as Ruby, not JS.
    expect(keywords).toContain("def")
    expect(keywords).toContain("end")
    // The `#` line is a Ruby comment (JavaScript would not treat `#` as a comment).
    expect(code.querySelector(".lexical-token-comment")).toBeTruthy()
  })

  it("re-highlights legacy blocks from textContent, dropping baked inline styles", () => {
    const el = document.createElement("div")
    // Simulates an old description whose stored HTML still carries syntect's
    // inline-styled spans and a dark <pre> background.
    el.innerHTML = '<pre lang="javascript" style="background-color:#2b303b;"><code>' +
      '<span style="color:#96b5b4;">const </span><span style="color:#a3be8c;">x = true</span></code></pre>'
    highlightCodeBlocks(el)
    const pre = el.querySelector("pre")
    const code = el.querySelector("pre code")
    expect(pre.getAttribute("style")).toBeNull()
    expect(code.innerHTML).not.toContain("#2b303b")
    expect(code.textContent).toBe("const x = true")
    expect(code.querySelector(".lexical-token-keyword")).toBeTruthy()
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
    el.innerHTML = '<pre lang="javascript"><code>const x = true</code></pre>'
    highlightCodeBlocks(el)
    const first = el.querySelector("pre code").innerHTML
    highlightCodeBlocks(el)
    expect(el.querySelector("pre code").innerHTML).toBe(first)
  })
})
