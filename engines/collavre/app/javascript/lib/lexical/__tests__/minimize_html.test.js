/**
 * @jest-environment jsdom
 */
import {
  createEditor,
  $getRoot,
  $createParagraphNode,
  $isElementNode,
  $isLineBreakNode,
  $isTextNode
} from "lexical"
import { HeadingNode, QuoteNode } from "@lexical/rich-text"
import { CodeNode, CodeHighlightNode } from "@lexical/code"
import { ListItemNode, ListNode } from "@lexical/list"
import { LinkNode, AutoLinkNode } from "@lexical/link"
import { $generateHtmlFromNodes, $generateNodesFromDOM } from "@lexical/html"
import { minimizeContentHtml } from "../minimize_html"

const theme = {
  paragraph: "lexical-paragraph",
  quote: "lexical-quote",
  heading: { h1: "lexical-heading-h1", h2: "lexical-heading-h2", h3: "lexical-heading-h3" },
  list: { ul: "lexical-list-ul", ol: "lexical-list-ol", listitem: "lexical-list-item" },
  code: "lexical-code-block",
  link: "lexical-link",
  text: {
    bold: "lexical-text-bold",
    italic: "lexical-text-italic",
    underline: "lexical-text-underline",
    strikethrough: "lexical-text-strike",
    code: "lexical-text-code"
  }
}

function newEditor() {
  return createEditor({
    namespace: "test",
    theme,
    nodes: [HeadingNode, QuoteNode, CodeNode, CodeHighlightNode, ListItemNode, ListNode, LinkNode, AutoLinkNode],
    onError: (e) => { throw e }
  })
}

// Replicate the editor's serialize step: render input -> Lexical HTML.
function serialize(inputHtml) {
  const editor = newEditor()
  editor.update(() => {
    const root = $getRoot()
    root.getChildren().forEach((c) => c.remove())
    const doc = new DOMParser().parseFromString(inputHtml, "text/html")
    root.append(...$generateNodesFromDOM(editor, doc.body))
  }, { discrete: true })
  let out = ""
  editor.getEditorState().read(() => { out = $generateHtmlFromNodes(editor) })
  return out
}

// Wrap raw Lexical HTML the way InlineLexicalEditor does, then minimize.
function minimize(lexicalHtml) {
  const doc = new DOMParser().parseFromString(`<div>${lexicalHtml}</div>`, "text/html")
  return minimizeContentHtml(doc.body.firstElementChild)
}

// Re-import minimized HTML and re-serialize: the second pass must be identical
// (stable round-trip) and preserve every text format flag.
function reimportFormats(minimizedHtml) {
  const editor = newEditor()
  editor.update(() => {
    const root = $getRoot()
    root.getChildren().forEach((c) => c.remove())
    const doc = new DOMParser().parseFromString(minimizedHtml, "text/html")
    const nodes = $generateNodesFromDOM(editor, doc.body)
    // Mirror InitialContentPlugin: group top-level inline/text runs into a <p>.
    let pending = null
    const flush = () => { if (pending) { root.append(pending); pending = null } }
    nodes.forEach((node) => {
      const inlineLeaf =
        $isTextNode(node) ||
        $isLineBreakNode(node) ||
        ($isElementNode(node) && node.isInline())
      if (inlineLeaf) {
        if (!pending) pending = $createParagraphNode()
        pending.append(node)
        return
      }
      flush()
      root.append(node)
    })
    flush()
  }, { discrete: true })
  let out = ""
  editor.getEditorState().read(() => { out = $generateHtmlFromNodes(editor) })
  return out
}

describe("minimizeContentHtml", () => {
  test("plain single line -> bare text, no wrapper", () => {
    expect(minimize(serialize("<p>Hello World</p>"))).toBe("Hello World")
  })

  test("strips the white-space:pre-wrap noise spans", () => {
    const out = minimize(serialize("<p>Hello World</p>"))
    expect(out).not.toContain("white-space")
    expect(out).not.toContain("<span")
  })

  test("bold keeps a single semantic tag with its class", () => {
    expect(minimize(serialize("<p><b>x</b></p>"))).toBe(
      '<strong class="lexical-text-bold">x</strong>'
    )
  })

  test("italic keeps a single em with its class", () => {
    expect(minimize(serialize("<p><i>x</i></p>"))).toBe(
      '<em class="lexical-text-italic">x</em>'
    )
  })

  test("partially styled line keeps text + minimal styled tag", () => {
    expect(minimize(serialize("<p>Hello <b>World</b></p>"))).toBe(
      'Hello <strong class="lexical-text-bold">World</strong>'
    )
  })

  test("nested bold+italic collapses outer duplicate but keeps both formats", () => {
    expect(minimize(serialize("<p><b><i>x</i></b></p>"))).toBe(
      '<i><strong class="lexical-text-bold lexical-text-italic">x</strong></i>'
    )
  })

  test("multiple paragraphs keep one <p> per line", () => {
    expect(minimize(serialize("<p>line1</p><p>line2</p>"))).toBe(
      '<p class="lexical-paragraph">line1</p><p class="lexical-paragraph">line2</p>'
    )
  })

  test("heading stays structural", () => {
    expect(minimize(serialize("<h1>Title</h1>"))).toBe(
      '<h1 class="lexical-heading-h1">Title</h1>'
    )
  })

  test("list stays structural", () => {
    expect(minimize(serialize("<ul><li>a</li><li>b</li></ul>"))).toBe(
      '<ul class="lexical-list-ul"><li value="1" class="lexical-list-item">a</li>' +
      '<li value="2" class="lexical-list-item">b</li></ul>'
    )
  })

  test("link keeps href + class, drops inner span", () => {
    const out = minimize(serialize('<p><a href="https://a.com">x</a></p>'))
    expect(out).toContain('href="https://a.com"')
    expect(out).toContain('class="lexical-link"')
    expect(out).not.toContain("<span")
    expect(out).not.toContain("white-space")
  })

  test("code block preserves structure and highlight classes", () => {
    const out = minimize(serialize("<pre><code>const a = 1</code></pre>"))
    expect(out).toContain("lexical-code-block")
    expect(out).toContain("const a = 1")
    expect(out).not.toContain("white-space")
    expect(out).not.toContain("spellcheck")
  })

  test("empty paragraph minimizes to empty/near-empty", () => {
    const out = minimize(serialize("<p></p>"))
    expect(out.replace(/<br\s*\/?>/g, "").trim()).toBe("")
  })

  test("keeps pre-wrap span when text has 2+ consecutive spaces", () => {
    // The render container has no `white-space: pre-wrap`, so significant
    // whitespace must survive in the persisted markup.
    const lexical =
      '<p class="lexical-paragraph">' +
      '<span style="white-space: pre-wrap;">foo  bar</span></p>'
    const out = minimize(lexical)
    expect(out).toContain("foo  bar")
    expect(out).toContain("white-space")
  })

  test("keeps pre-wrap span for leading indentation", () => {
    const lexical =
      '<p class="lexical-paragraph">' +
      '<span style="white-space: pre-wrap;">    indented</span></p>'
    const out = minimize(lexical)
    expect(out).toContain("    indented")
    expect(out).toContain("white-space")
  })

  test("a single trailing space stays minimal (not significant)", () => {
    // The "Hello " run has one trailing space — renders fine bare, so no span.
    expect(minimize(serialize("<p>Hello <b>World</b></p>"))).toBe(
      'Hello <strong class="lexical-text-bold">World</strong>'
    )
  })

  test("soft line break keeps its <p> wrapper", () => {
    const out = minimize(serialize("<p>line 1<br>line 2</p>"))
    expect(out).toContain("<br>")
    expect(out.startsWith("<p")).toBe(true)
    expect(out).toContain("line 1")
    expect(out).toContain("line 2")
  })

  // Round-trip stability: minimized HTML re-imported and re-serialized, then
  // minimized again, must equal the first minimization (no format loss / drift).
  const roundTripCases = [
    "<p>Hello World</p>",
    "<p>Hello <b>World</b></p>",
    "<p><b>x</b></p>",
    "<p><i>x</i></p>",
    "<p><u>x</u></p>",
    "<p><s>x</s></p>",
    "<p><b><i>x</i></b></p>",
    "<p><code>inline</code></p>",
    "<h1>Title</h1>",
    "<p>line1</p><p>line2</p>",
    "<ul><li>a</li><li>b</li></ul>",
    "<blockquote>quoted</blockquote>",
    '<p><a href="https://a.com">link</a></p>',
    "<p>line 1<br>line 2</p>"
  ]

  test.each(roundTripCases)("round-trip stable: %s", (input) => {
    const first = minimize(serialize(input))
    const second = minimize(reimportFormats(first))
    expect(second).toBe(first)
  })
})
