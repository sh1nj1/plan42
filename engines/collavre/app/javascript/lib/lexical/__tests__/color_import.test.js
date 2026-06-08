import { createEditor, $getRoot, $isTextNode, $createParagraphNode } from "lexical"
import { $generateNodesFromDOM } from "@lexical/html"
import { lexicalHtmlConfig, normalizeColoredContainers } from "../color_import"

// Parse an inline style string into a plain object so order doesn't matter.
function parseStyleMap(styleText) {
  const map = {}
  ;(styleText || "").split(";").forEach((decl) => {
    const idx = decl.indexOf(":")
    if (idx === -1) return
    const key = decl.slice(0, idx).trim()
    if (key) map[key] = decl.slice(idx + 1).trim()
  })
  return map
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
      if (withConfig) normalizeColoredContainers(doc.body)
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

  it("preserves non-format text styles (font-size/family/transform) on a colored span", () => {
    // The custom span import must carry the span's FULL style, not just color:
    // a colored span can also set font-size / font-family / text-transform /
    // letter-spacing, and Lexical's default conversion ignores them, so cherry-
    // picking color alone drops the rest on reopen.
    const html =
      '<p><span style="color: rgb(255, 0, 0); font-size: 20px; font-family: Georgia; ' +
      'text-transform: uppercase; letter-spacing: 2px; white-space: pre-wrap;">big</span></p>'

    const nodes = importColors(html, { withConfig: true })
    expect(nodes).toHaveLength(1)
    expect(nodes[0].text).toBe("big")
    // white-space (Lexical's own artifact) is intentionally dropped; everything
    // else survives.
    expect(parseStyleMap(nodes[0].style)).toEqual({
      color: "rgb(255, 0, 0)",
      "font-size": "20px",
      "font-family": "Georgia",
      "text-transform": "uppercase",
      "letter-spacing": "2px"
    })
    expect(nodes[0].formats).toEqual([])
  })

  it("preserves non-format text styles on a non-span colored block element", () => {
    // Same generality for the block path: a colored <p>/<li> carrying font-size
    // etc. must keep those styles when normalizeColoredContainers wraps its text.
    const html = '<p style="color: rgb(255, 0, 0); font-size: 20px;">big block</p>'

    const nodes = importColors(html, { withConfig: true })
    expect(nodes).toHaveLength(1)
    expect(nodes[0].text).toBe("big block")
    expect(parseStyleMap(nodes[0].style)).toEqual({
      color: "rgb(255, 0, 0)",
      "font-size": "20px"
    })
  })

  it("keeps an inner span's own color instead of inheriting the outer color", () => {
    // Pasted content nests colored spans. The outer span's after-callback runs
    // after the inner span is converted, so it must merge (inner color wins)
    // rather than clobber every descendant with the outer color.
    const html =
      '<p><span style="color: rgb(255, 0, 0);">outer ' +
      '<span style="color: rgb(0, 0, 255);">inner</span></span></p>'

    const nodes = importColors(html, { withConfig: true })
    expect(nodes.find((n) => n.text === "outer ").style).toBe("color: rgb(255, 0, 0)")
    expect(nodes.find((n) => n.text === "inner").style).toBe("color: rgb(0, 0, 255)")
  })

  it("preserves an inner span's background-color while inheriting the outer color", () => {
    const html =
      '<p><span style="color: rgb(255, 0, 0);">outer ' +
      '<span style="background-color: rgb(255, 255, 0);">inner</span></span></p>'

    const nodes = importColors(html, { withConfig: true })
    const inner = nodes.find((n) => n.text === "inner")
    expect(parseStyleMap(inner.style)).toEqual({
      "background-color": "rgb(255, 255, 0)",
      color: "rgb(255, 0, 0)"
    })
  })

  it("imports color carried on a non-span block element (e.g. <p style=color>)", () => {
    // Legacy / Trix-migrated / pasted content can put color on a block element
    // instead of a span. The span importer can't see it; normalizeColoredContainers
    // wraps the block's direct text in a span so the color survives reopen.
    const html = '<p style="color: rgb(255, 0, 0);">red paragraph</p>'

    const nodes = importColors(html, { withConfig: true })
    expect(nodes).toEqual([
      { text: "red paragraph", style: "color: rgb(255, 0, 0)", formats: [] }
    ])
  })

  it("preserves a non-span block element's own text formatting alongside its color", () => {
    // Pasted content can put color AND text formatting on a block element, e.g.
    // <p style="color:red; font-weight:700; font-style:italic">. The wrapper span
    // must carry those format styles too, or normalization drops the bold/italic.
    const html =
      '<p style="color: rgb(255, 0, 0); font-weight: 700; font-style: italic; ' +
      'text-decoration: underline;">styled block</p>'

    const nodes = importColors(html, { withConfig: true })
    expect(nodes).toHaveLength(1)
    expect(nodes[0].text).toBe("styled block")
    expect(nodes[0].style).toBe("color: rgb(255, 0, 0)")
    expect(nodes[0].formats.sort()).toEqual(["bold", "italic", "underline"].sort())
  })

  it("lets an inner colored span override the color of its non-span block parent", () => {
    const html =
      '<p style="color: rgb(255, 0, 0);">outer ' +
      '<span style="color: rgb(0, 0, 255);">inner</span></p>'

    const nodes = importColors(html, { withConfig: true })
    expect(nodes.find((n) => n.text === "outer ").style).toBe("color: rgb(255, 0, 0)")
    expect(nodes.find((n) => n.text === "inner").style).toBe("color: rgb(0, 0, 255)")
  })

  it("lets a nested span reset a text format the outer span turned on", () => {
    // applyTextFormatFromStyle only turns formats ON, so without dimension
    // tracking the outer span's after-callback re-bolds the inner text even
    // though the inner span explicitly reset font-weight. The nearer span must
    // win: an inner font-weight:normal un-bolds, while an inner span with no
    // weight declaration still inherits the outer bold.
    const reset = importColors(
      '<p><span style="color: rgb(255, 0, 0); font-weight: 700;">bold ' +
        '<span style="color: rgb(0, 0, 255); font-weight: normal;">normal</span></span></p>',
      { withConfig: true }
    )
    expect(reset.find((n) => n.text === "bold ").formats).toEqual(["bold"])
    expect(reset.find((n) => n.text === "normal").formats).toEqual([])

    const inherit = importColors(
      '<p><span style="color: rgb(255, 0, 0); font-weight: 700;">bold ' +
        '<span style="color: rgb(0, 0, 255);">still</span></span></p>',
      { withConfig: true }
    )
    expect(inherit.find((n) => n.text === "still").formats).toEqual(["bold"])
  })

  it("clears a tag-applied format when a colored span resets it", () => {
    // Lexical's default conversion toggles bold on for the <b> tag before the
    // colored span's after-callback runs. A reset value on the span (an
    // inherited CSS property) must actively un-bold the text, not just claim the
    // dimension — otherwise reopened/pasted content reopens as bold.
    const nodes = importColors(
      '<p><b><span style="color: rgb(255, 0, 0); font-weight: normal;">normal</span></b></p>',
      { withConfig: true }
    )
    expect(nodes).toEqual([
      { text: "normal", style: "color: rgb(255, 0, 0)", formats: [] }
    ])

    // Same for italic via <i> + font-style: normal.
    const italic = importColors(
      '<p><i><span style="color: rgb(255, 0, 0); font-style: normal;">upright</span></i></p>',
      { withConfig: true }
    )
    expect(italic.find((n) => n.text === "upright").formats).toEqual([])
  })

  it("keeps an inherited strikethrough when a colored span only adds underline", () => {
    // text-decoration propagates to descendants additively in CSS: an inner
    // `text-decoration: underline` does NOT remove an ancestor's line-through.
    // So a colored span must keep the tag-applied strikethrough and add underline
    // (add-only), unlike the inherited font-weight/font-style reset above.
    const nodes = importColors(
      '<p><s><span style="color: rgb(255, 0, 0); text-decoration: underline;">both</span></s></p>',
      { withConfig: true }
    )
    expect(nodes.find((n) => n.text === "both").formats.sort()).toEqual(
      ["strikethrough", "underline"].sort()
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
