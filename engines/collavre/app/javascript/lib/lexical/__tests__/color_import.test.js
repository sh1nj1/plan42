import { createEditor, $getRoot, $isTextNode, $createParagraphNode } from "lexical"
import { $generateNodesFromDOM } from "@lexical/html"
import { lexicalHtmlConfig } from "../color_import"

// The jsdom jest environment exposes `window`/`document`/`DOMParser`, but
// Lexical reaches for a few more browser globals at runtime.
for (const key of ["getComputedStyle", "MutationObserver", "Text", "HTMLElement"]) {
  if (typeof globalThis[key] === "undefined" && window[key]) {
    globalThis[key] = window[key]
  }
}

// Reproduces InlineLexicalEditor's InitialContentPlugin import path: parse the
// stored HTML, generate nodes, and read back each text node's color style.
function importColors(html, { withConfig }) {
  const editor = createEditor({
    namespace: "test",
    onError(error) {
      throw error
    },
    html: withConfig ? lexicalHtmlConfig : undefined
  })

  let result = []
  editor.update(
    () => {
      const root = $getRoot()
      root.getChildren().forEach((child) => child.remove())
      const doc = new DOMParser().parseFromString(html, "text/html")
      const nodes = $generateNodesFromDOM(editor, doc.body)
      nodes.forEach((node) => {
        if ($isTextNode(node)) {
          const paragraph = $createParagraphNode()
          paragraph.append(node)
          root.append(paragraph)
        } else {
          root.append(node)
        }
      })
      result = root.getAllTextNodes().map((node) => ({
        text: node.getTextContent(),
        style: node.getStyle(),
        formats: ["bold", "italic", "underline", "strikethrough", "subscript", "superscript"].filter(
          (f) => node.hasFormat(f)
        )
      }))
    },
    { discrete: true }
  )
  return result
}

describe("colorAwareSpanImport", () => {
  it("keeps the color on the correct node when stored HTML has inter-block whitespace", () => {
    // Lexical-exported HTML re-serialized by the server keeps a newline between
    // block tags. Lexical drops that whitespace-only text node on import, which
    // shifted positional color re-application onto the wrong node.
    const html =
      '<p><span style="white-space: pre-wrap;">hello</span></p>\n' +
      '<p><span style="color: rgb(255, 0, 0); white-space: pre-wrap;">RED</span></p>'

    const nodes = importColors(html, { withConfig: true })
    expect(nodes).toEqual([
      { text: "hello", style: "", formats: [] },
      { text: "RED", style: "color: rgb(255, 0, 0)", formats: [] }
    ])
  })

  it("keeps the color on the right node when a neighbouring pre-wrap span splits on a newline", () => {
    // `white-space: pre-wrap` makes Lexical split this span's text into two
    // nodes on the "\n", turning one DOM text node into two lexical nodes.
    const html =
      '<p><span style="white-space: pre-wrap;">line one\nline two</span></p>' +
      '<p><span style="color: rgb(0, 128, 0); white-space: pre-wrap;">GREEN</span></p>'

    const nodes = importColors(html, { withConfig: true })
    expect(nodes.map((n) => n.text)).toEqual(["line one", "line two", "GREEN"])
    expect(nodes.find((n) => n.text === "GREEN").style).toBe("color: rgb(0, 128, 0)")
    expect(nodes.find((n) => n.text === "line two").style).toBe("")
  })

  it("preserves background-color", () => {
    const html =
      '<p><span style="background-color: rgb(255, 255, 0); white-space: pre-wrap;">hi</span></p>'

    const nodes = importColors(html, { withConfig: true })
    expect(nodes).toEqual([
      { text: "hi", style: "background-color: rgb(255, 255, 0)", formats: [] }
    ])
  })

  it("preserves inline-style text formatting on a span that also carries color", () => {
    // Pasted content (Google Docs / Word) encodes bold/italic/underline as
    // inline span styles, not <b>/<i> tags. The custom span import must compose
    // those formats with the color binding instead of dropping them.
    const html =
      '<p><span style="color: rgb(255, 0, 0); font-weight: 700; font-style: italic; ' +
      'text-decoration: underline line-through; white-space: pre-wrap;">styled</span></p>'

    const nodes = importColors(html, { withConfig: true })
    expect(nodes).toHaveLength(1)
    expect(nodes[0].text).toBe("styled")
    expect(nodes[0].style).toBe("color: rgb(255, 0, 0)")
    expect(nodes[0].formats.sort()).toEqual(
      ["bold", "italic", "strikethrough", "underline"].sort()
    )
  })

  it("demonstrates the drift the fix removes (no config = color on wrong/lost node)", () => {
    const html =
      '<p><span style="white-space: pre-wrap;">hello</span></p>\n' +
      '<p><span style="color: rgb(255, 0, 0); white-space: pre-wrap;">RED</span></p>'

    // Without the color-aware import, Lexical's default span conversion ignores
    // color entirely, so "RED" comes back uncolored.
    const nodes = importColors(html, { withConfig: false })
    expect(nodes.find((n) => n.text === "RED").style).not.toContain("color: rgb(255, 0, 0)")
  })
})
