import { $isElementNode, $isTextNode } from "lexical"

// Tracks, per lexical text node, which format dimensions a nearer (more deeply
// nested) span has already decided during this import. Child span `after`
// callbacks run before their ancestors', so a nested span claims its
// dimensions first and an ancestor must not override them. Keyed by node, so
// entries fall away with the nodes; distinct nodes never collide across imports.
const decidedFormats = new WeakMap()

// Mirrors Lexical's internal applyTextFormatFromStyle (Lexical's
// convertSpanElement) for the inline-style text formats it reads off a <span>:
// font-weight / font-style / text-decoration / vertical-align. Lexical does not
// export it, so we replicate it here — our custom span import must COMPOSE these
// formats with the color binding, not bypass them. Pasted content (Google Docs,
// Word) carries bold/italic/underline as inline span styles rather than <b>/<i>
// tags, so dropping this would lose that formatting on reopen.
//
// `applyTextFormatFromStyle` only turns formats ON (toggleFormat when the value
// matches), so a nested span that RESETS a format — e.g.
// <span font-weight:700>bold <span font-weight:normal>normal</span></span> —
// cannot un-bold itself once an ancestor re-applies bold over every descendant.
// To honour resets we treat a dimension as "decided" by the FIRST (nearest)
// span that declares it at all: if the inner span sets font-weight (even to
// `normal`), it owns the bold dimension for that text and the outer span skips
// it. A span that omits a declaration leaves the dimension open, so the format
// still inherits from the ancestor (matching CSS).
function applyTextFormatFromStyle(node, domStyle) {
  const fontWeight = domStyle.fontWeight
  const textDecoration = domStyle.textDecoration
  const fontStyle = domStyle.fontStyle
  const verticalAlign = domStyle.verticalAlign
  const decorations = (textDecoration || "").split(" ")

  // [dimension declared by this span?, value matches the format?, format name]
  const rules = [
    [Boolean(fontWeight), fontWeight === "700" || fontWeight === "bold", "bold"],
    [Boolean(textDecoration), decorations.includes("line-through"), "strikethrough"],
    [Boolean(fontStyle), fontStyle === "italic", "italic"],
    [Boolean(textDecoration), decorations.includes("underline"), "underline"],
    [Boolean(verticalAlign), verticalAlign === "sub", "subscript"],
    [Boolean(verticalAlign), verticalAlign === "super", "superscript"]
  ]

  let decided = decidedFormats.get(node)
  rules.forEach(([declared, shouldApply, format]) => {
    if (decided && decided.has(format)) return
    if (shouldApply && !node.hasFormat(format)) {
      node.toggleFormat(format)
    }
    if (declared) {
      if (!decided) {
        decided = new Set()
        decidedFormats.set(node, decided)
      }
      decided.add(format)
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

// Lexical's html.import is keyed per tag, and colorAwareSpanImport only runs for
// <span>. Color / background-color that sits on a NON-span element — e.g.
// `<p style="color: red">text</p>`, a `<li>`/`<h1>` carrying color, or a
// materialized data-lexical-color on a block element (common in legacy /
// Trix-migrated or pasted content) — would otherwise be dropped on import,
// because Lexical's default block conversions ignore color. The removed
// positional collector read each text node's IMMEDIATE parent element regardless
// of tag, so it preserved these.
//
// Normalize the DOM before import: for each colored non-span element, wrap its
// DIRECT text-node children in a <span> carrying that element's color /
// background-color, so the span importer binds it like any other span. We only
// push onto direct text children (matching the old immediate-parent semantics) —
// nested colored elements keep their own color and win via the merge in
// applyStyleToTextNodes. Run this AFTER syncLexicalStyleAttributes so
// data-lexical-* attributes are already materialized into inline style.
const TEXT_NODE = 3

export function normalizeColoredContainers(root) {
  if (!root || typeof root.querySelectorAll !== "function") return
  const ownerDocument = root.ownerDocument || document

  root.querySelectorAll("[style]").forEach((element) => {
    if (element.tagName === "SPAN") return
    const { color, backgroundColor } = element.style
    if (!color && !backgroundColor) return

    Array.from(element.childNodes).forEach((child) => {
      if (child.nodeType !== TEXT_NODE || !child.nodeValue) return
      const span = ownerDocument.createElement("span")
      if (color) span.style.color = color
      if (backgroundColor) span.style.backgroundColor = backgroundColor
      element.replaceChild(span, child)
      span.appendChild(child)
    })
  })
}
