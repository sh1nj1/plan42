import {
  createEditor,
  $getRoot,
  $createParagraphNode,
  $createTextNode
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
  lexicalToMarkdown
} from "../markdown_serialize"

function buildEditor(builder) {
  const editor = createEditor({
    namespace: "test",
    onError(error) {
      throw error
    },
    nodes: [HeadingNode, QuoteNode, ListNode, ListItemNode, LinkNode, CodeNode, CodeHighlightNode]
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
    ]
  ]

  it.each(cases)("round-trips %s", (_name, html, expected) => {
    expect(importHtmlThenToMarkdown(html)).toBe(expected)
  })
})
