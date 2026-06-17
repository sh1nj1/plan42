import {
  createEditor,
  $getRoot,
  $createParagraphNode,
  $createTextNode,
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
  collapseParagraphBreaks
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

  it("joins consecutive plain paragraphs with a single newline", () => {
    const editor = buildEditor((root) => {
      const a = $createParagraphNode()
      a.append($createTextNode("abc"))
      root.append(a)
      const b = $createParagraphNode()
      b.append($createTextNode("def"))
      root.append(b)
    })
    // No blank line inserted between rich-editor lines (the user's request).
    expect(lexicalToMarkdown(editor)).toBe("abc\ndef")
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
})

describe("collapseParagraphBreaks", () => {
  it("collapses the blank line between two plain paragraphs", () => {
    expect(collapseParagraphBreaks("a\n\nb")).toBe("a\nb")
    expect(collapseParagraphBreaks("a\n\nb\n\nc")).toBe("a\nb\nc")
  })

  it("keeps blank lines around non-paragraph blocks", () => {
    expect(collapseParagraphBreaks("p\n\n## h")).toBe("p\n\n## h")
    expect(collapseParagraphBreaks("note\n\n- a\n- b")).toBe("note\n\n- a\n- b")
    expect(collapseParagraphBreaks("- a\n- b\n\ntail")).toBe("- a\n- b\n\ntail")
    expect(collapseParagraphBreaks("p\n\n> quote")).toBe("p\n\n> quote")
    expect(collapseParagraphBreaks('p\n\n<img src="/x.png" alt="x">')).toBe(
      'p\n\n<img src="/x.png" alt="x">'
    )
  })

  it("never collapses blank lines inside a fenced code block", () => {
    const md = "```js\nconst a = 1\n\nconst b = 2\n```"
    expect(collapseParagraphBreaks(md)).toBe(md)
    // ...and still collapses paragraphs around the protected fence
    expect(collapseParagraphBreaks("a\n\nb\n\n```\nx\n\ny\n```")).toBe(
      "a\nb\n\n```\nx\n\ny\n```"
    )
  })
})

// Reproduces the production import path: stored Markdown is rendered to HTML by
// the server (markdown_to_html, unsafe:true keeps the raw <span>), then imported
// into Lexical via $generateNodesFromDOM + the colorAwareSpanImport config. Then
// we re-serialize to Markdown and require byte-identity with the rendered HTML's
// intended source — guarding the md -> html -> lexical -> md round-trip.
function importHtmlThenToMarkdown(html) {
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
      nodes.forEach((node) => {
        if (node.getType && node.getType() === "text") {
          const p = $createParagraphNode()
          p.append(node)
          root.append(p)
        } else {
          root.append(node)
        }
      })
    },
    { discrete: true }
  )
  return lexicalToMarkdown(editor)
}

describe("round-trip: rendered HTML -> Lexical -> Markdown", () => {
  // [name, HTML as markdown_to_html would render it, expected canonical Markdown]
  const cases = [
    ["plain paragraph", "<p>hello</p>", "hello"],
    ["heading", "<h1>Title</h1>", "# Title"],
    ["bold", "<p><strong>bold</strong></p>", "**bold**"],
    ["italic", "<p><em>nice</em></p>", "*nice*"],
    ["unordered list", "<ul><li>a</li><li>b</li></ul>", "- a\n- b"],
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
    ]
  ]

  it.each(cases)("round-trips %s", (_name, html, expected) => {
    expect(importHtmlThenToMarkdown(html)).toBe(expected)
  })
})
