import { $isElementNode, $isTextNode } from "lexical"

// Mirrors Lexical's internal applyTextFormatFromStyle (Lexical's
// convertSpanElement) for the inline-style text formats it reads off a <span>:
// font-weight / font-style / text-decoration / vertical-align. Lexical does not
// export it, so we replicate it here — our custom span import must COMPOSE these
// formats with the color binding, not bypass them. Pasted content (Google Docs,
// Word) carries bold/italic/underline as inline span styles rather than <b>/<i>
// tags, so dropping this would lose that formatting on reopen.
function applyTextFormatFromStyle(node, domStyle) {
  const fontWeight = domStyle.fontWeight
  const textDecoration = (domStyle.textDecoration || "").split(" ")
  const verticalAlign = domStyle.verticalAlign

  const toggles = [
    [fontWeight === "700" || fontWeight === "bold", "bold"],
    [textDecoration.includes("line-through"), "strikethrough"],
    [domStyle.fontStyle === "italic", "italic"],
    [textDecoration.includes("underline"), "underline"],
    [verticalAlign === "sub", "subscript"],
    [verticalAlign === "super", "superscript"]
  ]

  toggles.forEach(([shouldApply, format]) => {
    if (shouldApply && !node.hasFormat(format)) {
      node.toggleFormat(format)
    }
  })
}

function parseStyle(styleText) {
  const map = new Map()
  ;(styleText || "").split(";").forEach((decl) => {
    const idx = decl.indexOf(":")
    if (idx === -1) return
    const key = decl.slice(0, idx).trim()
    const value = decl.slice(idx + 1).trim()
    if (key) map.set(key, value)
  })
  return map
}

function serializeStyle(map) {
  return Array.from(map.entries())
    .map(([key, value]) => `${key}: ${value}`)
    .join("; ")
}

// `inherited` is the parent span's color/background-color declarations as a Map.
// We MERGE rather than overwrite: a descendant text node that already carries
// its own color/background (from a deeper colored span converted first) keeps
// it — inner color wins, matching CSS inheritance. The parent only fills in
// declarations the node is missing. Clobbering here would turn nested content
// like <span color:red>outer <span color:blue>inner</span></span> all red.
function applyStyleToTextNodes(nodes, inherited, domStyle) {
  nodes.forEach((node) => {
    if ($isTextNode(node)) {
      const merged = parseStyle(node.getStyle())
      inherited.forEach((value, key) => {
        if (!merged.has(key)) merged.set(key, value)
      })
      node.setStyle(serializeStyle(merged))
      applyTextFormatFromStyle(node, domStyle)
    } else if ($isElementNode(node)) {
      applyStyleToTextNodes(node.getChildren(), inherited, domStyle)
    }
  })
}

// Custom HTML import for <span> that binds inline color / background-color to
// the text nodes it produces, at import time.
//
// Lexical's default span import (applyTextFormatFromStyle) only reads
// font-weight / font-style / text-decoration — it ignores color and
// background-color. The editor used to compensate by collecting one style per
// DOM text node and re-applying them positionally to root.getAllTextNodes()
// after import. That drifts whenever Lexical's importer does not produce a
// 1:1, same-order mapping of DOM text nodes to lexical text nodes — and it
// frequently does not:
//   - TextNode.exportDOM stamps `white-space: pre-wrap` on every span, so on
//     re-import isNodePre() is true and a span's text is split on "\n"/"\t"
//     into multiple nodes (one DOM text node -> N lexical nodes).
//   - whitespace-only text nodes (e.g. newlines between block tags in
//     server-stored / Trix-migrated HTML) are dropped on import but still
//     counted by the collector.
// Any such mismatch shifts every subsequent color onto the wrong text node, so
// reopening the editor showed the color applied somewhere else (or lost).
//
// Binding the color during conversion keeps it attached to the right node
// regardless of how Lexical splits or drops surrounding text.
export function colorAwareSpanImport(domNode) {
  const { color, backgroundColor } = domNode.style
  if (!color && !backgroundColor) {
    // Defer to Lexical's default span conversion (format-from-style).
    return null
  }

  const inherited = new Map()
  if (color) inherited.set("color", color)
  if (backgroundColor) inherited.set("background-color", backgroundColor)

  return {
    conversion: () => ({
      node: null,
      after: (childLexicalNodes) => {
        applyStyleToTextNodes(childLexicalNodes, inherited, domNode.style)
        return childLexicalNodes
      }
    }),
    priority: 1
  }
}

export const lexicalHtmlConfig = {
  import: {
    span: colorAwareSpanImport
  }
}
