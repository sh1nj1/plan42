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

// Markdown-mode preview and chat/comment code blocks must use the SAME Prism
// engine + `lexical-token-*` classes as the editor and rendered creative view —
// not highlight.js's `hljs-*` — so a fenced block looks identical everywhere it
// is rendered. (highlight.js produces a different palette/tokenization, which is
// why these surfaces visibly diverged from the editor.)
describe("markdown renderers use the shared Prism token classes", () => {
  it("renderMarkdown (preview) tokenizes a fenced ruby block with lexical-token classes", () => {
    const html = renderMarkdown("```ruby\ndef foo\n  true\nend\n```")
    expect(html).toContain("lexical-token-")
    expect(html).not.toContain("hljs-")
    const keywords = (html.match(/lexical-token-keyword/g) || [])
    expect(keywords.length).toBeGreaterThan(0) // def / end
  })

  it("renderCommentMarkdown tokenizes a fenced javascript block with lexical-token classes", () => {
    const html = renderCommentMarkdown("```javascript\nconst x = true\n```")
    expect(html).toContain("lexical-token-")
    expect(html).not.toContain("hljs-")
  })

  it("honors an explicit fence language instead of re-detecting it (matches the editor)", () => {
    // ruby fence over JS-looking content: detection alone would pick javascript;
    // the editor/view honor the explicit fence, so the preview must too.
    const html = renderMarkdown("```ruby\nconst x = function() {}\n```")
    expect(html).toContain('lang="ruby"')
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

  const RUBY_SRC =
    '# frozen_string_literal: true\n' +
    'module CollavreCompat\n' +
    '  module_function\n' +
    '  def call(receiver, method_name, *args, **kwargs)\n' +
    '    receiver.public_send(method_name, *args, **kwargs)\n' +
    '  end\n' +
    'end'

  it("honors an explicit javascript label instead of re-detecting it (matches the editor)", () => {
    // The user can deliberately choose ```javascript. The view must honor it
    // verbatim — same as the editor, which honors any import-resolved language —
    // so edit and view never disagree. (Previously the view re-detected this to
    // Ruby, which contradicted an explicit choice.)
    const el = document.createElement("div")
    el.innerHTML = '<pre lang="javascript"><code>' + RUBY_SRC + '</code></pre>'
    highlightCodeBlocks(el)
    const code = el.querySelector("pre code")
    const keywords = Array.from(code.querySelectorAll(".lexical-token-keyword")).map((s) => s.textContent)
    // Ruby's `def`/`end` are NOT JavaScript keywords — proof it tokenized as JS,
    // i.e. the explicit label was honored rather than overridden to Ruby.
    expect(keywords).not.toContain("def")
    expect(keywords).not.toContain("end")
  })

  it("content-detects an UNLABELED Ruby block and tokenizes as ruby", () => {
    // No fence language → fall back to content detection so the block is colored.
    const el = document.createElement("div")
    el.innerHTML = '<pre><code>' + RUBY_SRC + '</code></pre>'
    highlightCodeBlocks(el)
    const code = el.querySelector("pre code")
    const keywords = Array.from(code.querySelectorAll(".lexical-token-keyword")).map((s) => s.textContent)
    expect(keywords).toContain("def")
    expect(keywords).toContain("end")
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

// Server-generated inbox/system comments embed a creative's plain-text label in
// a markdown link: `[#{label}](#{path})`. Collavre::HtmlText.markdown_label
// backslash-escapes the label before that interpolation; these cases pin down
// what those escapes have to survive on the rendering side.
describe("generated creative links tolerate hostile labels once escaped", () => {
  const link = (label) => renderCommentMarkdown(`[${label}](/creatives/1)`)
  const hrefOf = (html) => {
    const el = document.createElement("div")
    el.innerHTML = html
    return el.querySelector("a")?.getAttribute("href")
  }
  const textOf = (html) => {
    const el = document.createElement("div")
    el.innerHTML = html
    return el.querySelector("a")?.textContent
  }

  it("keeps an unescaped angle-bracket label from being dropped once escaped", () => {
    // Raw `<x>` reaches marked as inline HTML and the sanitizer deletes it.
    expect(textOf(link("A <x> tag"))).toBe("A  tag")
    // `\<x\>` renders the brackets as literal text instead.
    expect(textOf(link("A \\<x\\> tag"))).toBe("A <x> tag")
  })

  it("keeps a bracket-injecting label from hijacking the link destination", () => {
    // Unescaped, the label closes the link early and supplies its own href.
    expect(hrefOf(link("x](https://evil.example)"))).toBe("https://evil.example")
    // Escaped, the destination stays the creative path and the label is literal.
    const safe = link("x\\]\\(https://evil.example\\)")
    expect(hrefOf(safe)).toBe("/creatives/1")
    expect(textOf(safe)).toBe("x](https://evil.example)")
  })

  it("renders escaped emphasis and code characters as literal label text", () => {
    expect(textOf(link("a\\*b\\*c \\_d\\_ \\`e\\` \\~f\\~"))).toBe("a*b*c _d_ `e` ~f~")
  })

  it("leaves an ordinary label untouched", () => {
    const html = link("버그: 채팅 컨텍스트 라벨")
    expect(hrefOf(html)).toBe("/creatives/1")
    expect(textOf(html)).toBe("버그: 채팅 컨텍스트 라벨")
  })
})
