import {
  createEditor,
  $getRoot,
  $createParagraphNode,
  $createTextNode,
  $createLineBreakNode,
  $isTextNode,
  $isLineBreakNode,
  $isElementNode,
  DecoratorNode
} from "lexical"
import { HeadingNode, QuoteNode, $createHeadingNode } from "@lexical/rich-text"
import { ListNode, ListItemNode } from "@lexical/list"
import { LinkNode } from "@lexical/link"
import { CodeNode, CodeHighlightNode } from "@lexical/code"
import { $generateNodesFromDOM } from "@lexical/html"
import { lexicalHtmlConfig, normalizeColoredContainers } from "../color_import"
import {
  colorSpanMarkup,
  imageMarkup,
  videoMarkup,
  attachmentMarkup,
  lexicalToMarkdown,
  normalizeMarkdownBlankLines,
  splitBlankLineParagraphs
} from "../markdown_serialize"

// Minimal DecoratorNode stand-in: the production image/video/attachment nodes
// are .jsx and can't load under native-ESM Jest, but the serializer only
// duck-types getType()/getSrc()/etc., so a plain-JS DecoratorNode subclass
// exercises the same export path — including the top-level (root child) case.
class TestImageNode extends DecoratorNode {
  static getType() {
    return "image"
  }

  static clone(node) {
    return new TestImageNode(node.__src, node.__altText, node.__key)
  }

  constructor(src = "", altText = "", key) {
    super(key)
    this.__src = src
    this.__altText = altText
  }

  getSrc() {
    return this.__src
  }

  getAltText() {
    return this.__altText
  }

  createDOM() {
    return document.createElement("span")
  }

  updateDOM() {
    return false
  }

  decorate() {
    return null
  }
}

function buildEditor(builder, extraNodes = []) {
  const editor = createEditor({
    namespace: "test",
    onError(error) {
      throw error
    },
    nodes: [
      HeadingNode,
      QuoteNode,
      ListNode,
      ListItemNode,
      LinkNode,
      CodeNode,
      CodeHighlightNode,
      ...extraNodes
    ]
  })
  editor.update(
    () => {
      const root = $getRoot()
      root.clear()
      builder(root)
    },
    { discrete: true }
  )
  return editor
}

describe("colorSpanMarkup", () => {
  it("wraps inner text in a normalized color span", () => {
    expect(colorSpanMarkup("color: rgb(255, 0, 0)", "hi")).toBe(
      '<span style="color: rgb(255, 0, 0)">hi</span>'
    )
  })

  it("emits color first, then background-color, regardless of input order", () => {
    expect(
      colorSpanMarkup("background-color: rgb(0, 255, 0); color: #ff0000", "x")
    ).toBe('<span style="color: #ff0000; background-color: rgb(0, 255, 0)">x</span>')
  })

  it("supports background-color only", () => {
    expect(colorSpanMarkup("background-color: #ffff00", "y")).toBe(
      '<span style="background-color: #ffff00">y</span>'
    )
  })

  it("allows CSS custom properties", () => {
    expect(colorSpanMarkup("color: var(--color-danger)", "z")).toBe(
      '<span style="color: var(--color-danger)">z</span>'
    )
  })

  it("returns null when no color/background present", () => {
    expect(colorSpanMarkup("font-size: 12px", "n")).toBeNull()
    expect(colorSpanMarkup("", "n")).toBeNull()
  })

  it("drops dangerous CSS values (url, expression, injection)", () => {
    expect(colorSpanMarkup("color: url(javascript:alert(1))", "n")).toBeNull()
    expect(colorSpanMarkup('color: red"><script>', "n")).toBeNull()
    expect(colorSpanMarkup("color: expression(alert(1))", "n")).toBeNull()
  })

  it("HTML-escapes the inner text so it can't become raw markup", () => {
    expect(colorSpanMarkup("color: #ff0000", "<img src=x onerror=alert(1)>")).toBe(
      '<span style="color: #ff0000">&lt;img src=x onerror=alert(1)&gt;</span>'
    )
    expect(colorSpanMarkup("color: #ff0000", "a & b < c")).toBe(
      '<span style="color: #ff0000">a &amp; b &lt; c</span>'
    )
  })
})

describe("decorator markup", () => {
  it("emits a clean <img> and drops the inherit sentinel", () => {
    expect(imageMarkup({ src: "/x.png", altText: "cat", width: "inherit", height: "inherit" })).toBe(
      '<img src="/x.png" alt="cat">'
    )
    expect(imageMarkup({ src: "/x.png", altText: "cat", width: 200, height: 100 })).toBe(
      '<img src="/x.png" alt="cat" width="200" height="100">'
    )
  })

  it("escapes attribute values", () => {
    expect(imageMarkup({ src: '/a.png"', altText: "<b>" })).toBe(
      '<img src="/a.png&quot;" alt="&lt;b&gt;">'
    )
  })

  it("emits a controls <video>", () => {
    expect(videoMarkup({ src: "/v.mp4" })).toBe('<video controls src="/v.mp4"></video>')
  })

  it("emits a download <a> with filesize", () => {
    expect(attachmentMarkup({ src: "/f.pdf", filename: "doc.pdf", filesize: 1234 })).toBe(
      '<a href="/f.pdf" download="doc.pdf" data-filesize="1234">doc.pdf</a>'
    )
    expect(attachmentMarkup({ src: "/f.pdf", filename: "doc.pdf" })).toBe(
      '<a href="/f.pdf" download="doc.pdf">doc.pdf</a>'
    )
  })
})

describe("lexicalToMarkdown", () => {
  it("serializes a plain paragraph", () => {
    const editor = buildEditor((root) => {
      const p = $createParagraphNode()
      p.append($createTextNode("hello world"))
      root.append(p)
    })
    expect(lexicalToMarkdown(editor)).toBe("hello world")
  })

  it("serializes headings and bold via upstream transformers", () => {
    const editor = buildEditor((root) => {
      const h = $createHeadingNode("h1")
      h.append($createTextNode("Title"))
      root.append(h)
      const p = $createParagraphNode()
      const bold = $createTextNode("strong")
      bold.toggleFormat("bold")
      p.append(bold)
      root.append(p)
    })
    expect(lexicalToMarkdown(editor)).toBe("# Title\n\n**strong**")
  })

  it("wraps colored text in a span fragment", () => {
    const editor = buildEditor((root) => {
      const p = $createParagraphNode()
      const t = $createTextNode("red")
      t.setStyle("color: rgb(255, 0, 0)")
      p.append(t)
      root.append(p)
    })
    expect(lexicalToMarkdown(editor)).toBe('<span style="color: rgb(255, 0, 0)">red</span>')
  })

  it("composes bold with color (format inside the span)", () => {
    const editor = buildEditor((root) => {
      const p = $createParagraphNode()
      const t = $createTextNode("hot")
      t.setStyle("color: #ff0000")
      t.toggleFormat("bold")
      p.append(t)
      root.append(p)
    })
    expect(lexicalToMarkdown(editor)).toBe('<span style="color: #ff0000">**hot**</span>')
  })

  it("serializes a top-level media decorator (root child, not inside a paragraph)", () => {
    const editor = buildEditor((root) => {
      root.append(new TestImageNode("/u.png", "up"))
    }, [TestImageNode])
    // Without an element-type transformer, a top-level decorator falls back to
    // getTextContent() ("") and the image is silently dropped from markdown_source.
    expect(lexicalToMarkdown(editor)).toBe('<img src="/u.png" alt="up">')
  })

  it("serializes a top-level media decorator alongside text", () => {
    const editor = buildEditor((root) => {
      const p = $createParagraphNode()
      p.append($createTextNode("before"))
      root.append(p)
      root.append(new TestImageNode("/u.png", "up"))
    }, [TestImageNode])
    expect(lexicalToMarkdown(editor)).toBe('before\n\n<img src="/u.png" alt="up">')
  })

  it("leaves uncolored neighbours as plain markdown", () => {
    const editor = buildEditor((root) => {
      const p = $createParagraphNode()
      p.append($createTextNode("plain "))
      const t = $createTextNode("blue")
      t.setStyle("color: blue")
      p.append(t)
      root.append(p)
    })
    expect(lexicalToMarkdown(editor)).toBe('plain <span style="color: blue">blue</span>')
  })

  it("separates consecutive paragraphs with a standard blank line", () => {
    const editor = buildEditor((root) => {
      const a = $createParagraphNode()
      a.append($createTextNode("abc"))
      root.append(a)
      const b = $createParagraphNode()
      b.append($createTextNode("def"))
      root.append(b)
    })
    // Enter produces a real paragraph break: standard Markdown `\n\n`, no marker
    // characters in the canonical source (the user's "stray space" complaint).
    expect(lexicalToMarkdown(editor)).toBe("abc\n\ndef")
  })

  it("keeps a blank line between a paragraph and a heading", () => {
    const editor = buildEditor((root) => {
      const p = $createParagraphNode()
      p.append($createTextNode("intro"))
      root.append(p)
      const h = $createHeadingNode("h2")
      h.append($createTextNode("Sec"))
      root.append(h)
    })
    expect(lexicalToMarkdown(editor)).toBe("intro\n\n## Sec")
  })

  it("renders an empty paragraph as a single <br> marker (preserves the blank line)", () => {
    const editor = buildEditor((root) => {
      const a = $createParagraphNode()
      a.append($createTextNode("abc"))
      root.append(a)
      root.append($createParagraphNode()) // user pressed Enter on an empty line
      const b = $createParagraphNode()
      b.append($createTextNode("def"))
      root.append(b)
    })
    // The blank line the user typed is preserved as a semantic <br> marker (not a
    // stray space, and not collapsed away): standard paragraph separation around
    // a single <br>. The <br> renders as a visible blank line and round-trips.
    expect(lexicalToMarkdown(editor)).toBe("abc\n\n<br>\n\ndef")
  })

  it("preserves multiple consecutive blank lines, one <br> per line", () => {
    const editor = buildEditor((root) => {
      const a = $createParagraphNode()
      a.append($createTextNode("abc"))
      root.append(a)
      root.append($createParagraphNode())
      root.append($createParagraphNode())
      const b = $createParagraphNode()
      b.append($createTextNode("def"))
      root.append(b)
    })
    // Two empty paragraphs (two Enters) keep their exact count as two <br>
    // markers \u2014 the standard-paragraph model collapsed these to one blank line.
    expect(lexicalToMarkdown(editor)).toBe("abc\n\n<br>\n\n<br>\n\ndef")
  })

  it("serializes a blank paragraph of N line breaks as N <br> markers", () => {
    // On reopen the importer groups N consecutive <br> elements into ONE
    // paragraph holding N LineBreakNodes. Export must emit exactly N markers
    // (not N+1) or blank lines multiply on every save.
    const editor = buildEditor((root) => {
      const a = $createParagraphNode()
      a.append($createTextNode("abc"))
      root.append(a)
      const blanks = $createParagraphNode()
      blanks.append($createLineBreakNode())
      blanks.append($createLineBreakNode())
      root.append(blanks)
      const b = $createParagraphNode()
      b.append($createTextNode("def"))
      root.append(b)
    })
    expect(lexicalToMarkdown(editor)).toBe("abc\n\n<br>\n\n<br>\n\ndef")
  })

  it("serializes an editor that holds only empty paragraphs as empty Markdown", () => {
    const editor = buildEditor((root) => {
      root.append($createParagraphNode())
      root.append($createParagraphNode())
    })
    // A document with no real content stays empty (no stray nbsp), matching the
    // pre-existing empty-state contract so placeholders/presence checks hold.
    expect(lexicalToMarkdown(editor)).toBe("")
  })

  it("separates plain paragraphs with a blank line and keeps an empty one as <br>", () => {
    const editor = buildEditor((root) => {
      const a = $createParagraphNode()
      a.append($createTextNode("abc"))
      root.append(a)
      const b = $createParagraphNode()
      b.append($createTextNode("def"))
      root.append(b)
      root.append($createParagraphNode())
      const c = $createParagraphNode()
      c.append($createTextNode("ghi"))
      root.append(c)
    })
    // abc/def are adjacent paragraphs (standard \n\n separation); the empty
    // paragraph before ghi is a deliberate blank line, kept as a <br>.
    expect(lexicalToMarkdown(editor)).toBe("abc\n\ndef\n\n<br>\n\nghi")
  })
})

describe("normalizeMarkdownBlankLines", () => {
  it("keeps the standard blank line between two plain paragraphs", () => {
    expect(normalizeMarkdownBlankLines("a\n\nb")).toBe("a\n\nb")
    expect(normalizeMarkdownBlankLines("a\n\nb\n\nc")).toBe("a\n\nb\n\nc")
  })

  it("collapses runs of 3+ newlines to one standard blank line", () => {
    expect(normalizeMarkdownBlankLines("a\n\n\nb")).toBe("a\n\nb")
    expect(normalizeMarkdownBlankLines("a\n\n\n\n\nb")).toBe("a\n\nb")
  })

  it("returns empty string for blank-only input (empty-state contract)", () => {
    expect(normalizeMarkdownBlankLines("")).toBe("")
    expect(normalizeMarkdownBlankLines("\n")).toBe("")
    expect(normalizeMarkdownBlankLines("\n\n  \n")).toBe("")
  })

  it("treats a document of only <br> markers as empty (empty-state contract)", () => {
    // A creative the user filled with nothing but blank lines carries no real
    // content, so it stays empty (placeholders/presence checks unchanged).
    expect(normalizeMarkdownBlankLines("<br>")).toBe("")
    expect(normalizeMarkdownBlankLines("<br>\n\n<br>")).toBe("")
  })

  it("trims trailing whitespace", () => {
    expect(normalizeMarkdownBlankLines("abc\n\n\n")).toBe("abc")
    expect(normalizeMarkdownBlankLines("abc  \n")).toBe("abc")
  })

  it("never collapses blank lines inside a fenced code block", () => {
    const md = "```js\nconst a = 1\n\n\nconst b = 2\n```"
    expect(normalizeMarkdownBlankLines(md)).toBe(md)
    // ...and still normalizes blank-line runs around the protected fence
    expect(normalizeMarkdownBlankLines("a\n\n\nb\n\n```\nx\n\n\ny\n```")).toBe(
      "a\n\nb\n\n```\nx\n\n\ny\n```"
    )
  })

  it("never rewrites a literal <br> inside an inline code span", () => {
    // The rich editor exports inline code whose text is `<br>` as `` `<br>` ``.
    // The blank-line normalizer must not treat that as a marker and inject
    // blank lines, which would break the code span on save.
    expect(normalizeMarkdownBlankLines("Here is `<br>` literal code")).toBe(
      "Here is `<br>` literal code"
    )
    expect(normalizeMarkdownBlankLines("a `<br>` b")).toBe("a `<br>` b")
    expect(normalizeMarkdownBlankLines("`<br>`")).toBe("`<br>`")
    // A real marker on its own line is still isolated even alongside a code span
    expect(normalizeMarkdownBlankLines("a `<br>` b\n<br>\nc")).toBe(
      "a `<br>` b\n\n<br>\n\nc"
    )
  })

  it("only isolates a <br> that is the whole blank-line marker line", () => {
    // A blank-line marker is always emitted alone on its line (see
    // BLANK_PARAGRAPH_TRANSFORMER). A <br> embedded inside a line of other
    // content is an in-paragraph hard break / raw HTML, NOT a marker, so the
    // normalizer must leave it (and its surroundings) untouched — injecting
    // blank lines around it would rewrite user-authored HTML on save.
    expect(normalizeMarkdownBlankLines("<span>foo<br>bar</span>")).toBe(
      "<span>foo<br>bar</span>"
    )
    expect(normalizeMarkdownBlankLines("a<br>b")).toBe("a<br>b")
    expect(normalizeMarkdownBlankLines("foo <br> bar")).toBe("foo <br> bar")
    // A standalone marker line embedded next to inline-<br> text: only the
    // whole-line marker is isolated; the inline one is preserved verbatim.
    expect(normalizeMarkdownBlankLines("a<br>b\n<br>\nc<br>d")).toBe(
      "a<br>b\n\n<br>\n\nc<br>d"
    )
  })

  it("migrates legacy NBSP blank-line markers to <br> on save", () => {
    // Pre-<br> content stored blank lines as a line of only U+00A0. Reopening
    // and saving must clean it to a real <br> marker so CommonMark stops
    // treating the following block as a lazy list continuation.
    expect(normalizeMarkdownBlankLines("abc\n \ndef")).toBe(
      "abc\n\n<br>\n\ndef"
    )
    // ...and a NBSP marker right after a list is isolated as its own block
    expect(
      normalizeMarkdownBlankLines("- a\n- b\n \nXXX")
    ).toBe("- a\n- b\n\n<br>\n\nXXX")
    // A NBSP inside inline code is left untouched
    expect(normalizeMarkdownBlankLines("see ` ` here")).toBe(
      "see ` ` here"
    )
  })
})

// Reproduces the production import path: stored Markdown is rendered to HTML by
// the server (markdown_to_html, unsafe:true keeps the raw <span>), then imported
// into Lexical via $generateNodesFromDOM + the colorAwareSpanImport config. Then
// we re-serialize to Markdown and require byte-identity with the rendered HTML's
// intended source — guarding the md -> html -> lexical -> md round-trip.
function importHtml(html) {
  const editor = createEditor({
    namespace: "test",
    onError(error) {
      throw error
    },
    nodes: [HeadingNode, QuoteNode, ListNode, ListItemNode, LinkNode, CodeNode, CodeHighlightNode],
    html: lexicalHtmlConfig
  })
  editor.update(
    () => {
      const root = $getRoot()
      root.clear()
      const doc = new DOMParser().parseFromString(html, "text/html")
      normalizeColoredContainers(doc.body)
      const nodes = $generateNodesFromDOM(editor, doc.body)
      // Mirror InlineLexicalEditor's import grouping: text nodes, line breaks,
      // and inline elements can't be root children, so consecutive inline leaves
      // are grouped back into a single paragraph. This is what merges adjacent
      // <br> markers into ONE blank paragraph holding N LineBreakNodes — the
      // exact structure the blank-paragraph export rule must round-trip.
      let pending = null
      const flush = () => {
        if (pending) {
          root.append(pending)
          pending = null
        }
      }
      nodes.forEach((node) => {
        const isInlineLeaf =
          $isTextNode(node) ||
          $isLineBreakNode(node) ||
          ($isElementNode(node) && node.isInline())
        if (isInlineLeaf) {
          if (!pending) pending = $createParagraphNode()
          pending.append(node)
          return
        }
        flush()
        root.append(node)
      })
      flush()
      // Mirror InlineLexicalEditor: a grouped blank-line marker paragraph (only
      // LineBreakNodes) is split back into N empty paragraphs so reopened blank
      // lines match the structure fresh typing produces.
      splitBlankLineParagraphs(root)
    },
    { discrete: true }
  )
  return editor
}

// Structure of the root's children, for asserting that blank-line markers import
// as EMPTY paragraphs (one visual line each) rather than LineBreakNode-bearing
// paragraphs (which Lexical renders with an extra trailing line).
function importHtmlToStructure(html) {
  const editor = importHtml(html)
  let summary = []
  editor.getEditorState().read(() => {
    summary = $getRoot()
      .getChildren()
      .map((child) => ({
        type: child.getType(),
        childCount: child.getChildrenSize ? child.getChildrenSize() : 0,
        lineBreaks: child.getChildren
          ? child.getChildren().filter($isLineBreakNode).length
          : 0,
        text: child.getTextContent()
      }))
  })
  return summary
}

function importHtmlThenToMarkdown(html) {
  return lexicalToMarkdown(importHtml(html))
}

describe("round-trip: rendered HTML -> Lexical -> Markdown", () => {
  // [name, HTML as markdown_to_html would render it, expected canonical Markdown]
  const cases = [
    ["plain paragraph", "<p>hello</p>", "hello"],
    ["heading", "<h1>Title</h1>", "# Title"],
    ["bold", "<p><strong>bold</strong></p>", "**bold**"],
    ["italic", "<p><em>nice</em></p>", "*nice*"],
    ["unordered list", "<ul><li>a</li><li>b</li></ul>", "- a\n- b"],
    // Nested list produced by Tab indentation (markdown-canonical store).
    ["nested unordered list", "<ul><li>a<ul><li>b</li></ul></li></ul>", "- a\n    - b"],
    [
      "colored text",
      '<p><span style="color: rgb(255, 0, 0)">red</span></p>',
      '<span style="color: rgb(255, 0, 0)">red</span>'
    ],
    [
      "background color",
      '<p><span style="background-color: rgb(255, 255, 0)">hi</span></p>',
      '<span style="background-color: rgb(255, 255, 0)">hi</span>'
    ],
    [
      "bold + color",
      '<p><span style="color: rgb(255, 0, 0)"><strong>hot</strong></span></p>',
      '<span style="color: rgb(255, 0, 0)">**hot**</span>'
    ],
    [
      "colored text with HTML metacharacters",
      '<p><span style="color: rgb(255, 0, 0)">&lt;tag&gt; &amp; x</span></p>',
      '<span style="color: rgb(255, 0, 0)">&lt;tag&gt; &amp; x</span>'
    ],
    // Two adjacent paragraphs (no deliberate blank line between them) keep the
    // standard `\n\n` separation and no <br> marker is introduced.
    ["two adjacent paragraphs", "<p>abc</p><p>def</p>", "abc\n\ndef"],
    // A deliberate blank line is a <br>. markdown_to_html renders
    // `abc\n\n<br>\n\ndef` as <p>abc</p><br><p>def</p>; the importer groups the
    // <br> into a blank paragraph and re-export emits exactly one <br>.
    ["single blank line", "<p>abc</p>\n<br>\n<p>def</p>", "abc\n\n<br>\n\ndef"],
    // Two consecutive <br> markers come back as ONE paragraph of two
    // LineBreakNodes; the count must be preserved (no multiplication on re-save).
    [
      "two blank lines",
      "<p>abc</p>\n<br>\n<br>\n<p>def</p>",
      "abc\n\n<br>\n\n<br>\n\ndef"
    ],
    // A blank line right after a list no longer bleeds into the last <li>: the
    // list closes and the <br> + following text serialize as their own blocks.
    [
      "blank line after a list",
      "<ul>\n<li>test</li>\n<li>OK</li>\n</ul>\n<br>\n<p>XXXXXXX</p>",
      "- test\n- OK\n\n<br>\n\nXXXXXXX"
    ]
  ]

  it.each(cases)("round-trips %s", (_name, html, expected) => {
    expect(importHtmlThenToMarkdown(html)).toBe(expected)
  })
})

describe("import structure: blank-line markers become empty paragraphs", () => {
  // The bug: a single typed blank line is an EMPTY paragraph (zero children,
  // one visual line). On reopen the server renders it as a standalone <br>,
  // which imports as a paragraph holding a LineBreakNode — and Lexical renders
  // that as TWO lines (the break starts a new line on top of the paragraph's
  // own line). So the blank line grew by one on every reopen. After the fix a
  // blank-line marker imports as an empty paragraph, matching fresh typing.
  it("imports a single blank line as one empty paragraph (not a LineBreakNode)", () => {
    const structure = importHtmlToStructure("<p>Test</p>\n<br>\n<p>a</p>")
    expect(structure).toEqual([
      { type: "paragraph", childCount: 1, lineBreaks: 0, text: "Test" },
      { type: "paragraph", childCount: 0, lineBreaks: 0, text: "" },
      { type: "paragraph", childCount: 1, lineBreaks: 0, text: "a" }
    ])
  })

  it("imports N consecutive blank lines as N empty paragraphs", () => {
    const structure = importHtmlToStructure("<p>abc</p>\n<br>\n<br>\n<p>def</p>")
    expect(structure).toEqual([
      { type: "paragraph", childCount: 1, lineBreaks: 0, text: "abc" },
      { type: "paragraph", childCount: 0, lineBreaks: 0, text: "" },
      { type: "paragraph", childCount: 0, lineBreaks: 0, text: "" },
      { type: "paragraph", childCount: 1, lineBreaks: 0, text: "def" }
    ])
  })

  it("leaves an in-paragraph line break (text + <br>) untouched", () => {
    // A paragraph that mixes text and a break is NOT a blank-line marker; it
    // must keep its LineBreakNode so real soft breaks survive.
    const structure = importHtmlToStructure("<p>line1<br>line2</p>")
    expect(structure).toEqual([
      { type: "paragraph", childCount: 3, lineBreaks: 1, text: "line1\nline2" }
    ])
  })

  it("splitBlankLineParagraphs preserves the exported <br> count (round-trip stable)", () => {
    // After splitting, re-export still emits exactly N markers.
    expect(importHtmlThenToMarkdown("<p>Test</p>\n<br>\n<p>a</p>")).toBe("Test\n\n<br>\n\na")
    expect(importHtmlThenToMarkdown("<p>abc</p>\n<br>\n<br>\n<p>def</p>")).toBe(
      "abc\n\n<br>\n\n<br>\n\ndef"
    )
  })
})
