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
//
// Declaring a dimension is also not enough when an ANCESTOR TAG (<b>/<strong>,
// <i>/<em>) already toggled the format on via Lexical's default conversion —
// e.g. <b><span font-weight:normal>normal</span></b>. Our span `after` callback
// runs after that tag's forChild, so for genuinely-inherited CSS properties
// (font-weight, font-style) a reset value must actively CLEAR the format, not
// just claim the dimension. text-decoration and vertical-align are NOT cleared
// on a non-matching value: in CSS those propagate to descendants additively
// (an inner `text-decoration: underline` does not remove an ancestor's
// line-through), so they stay add-only to avoid stripping inherited decorations.
function applyTextFormatFromStyle(node, domStyle) {
  const fontWeight = domStyle.fontWeight
  const textDecoration = domStyle.textDecoration
  const fontStyle = domStyle.fontStyle
  const verticalAlign = domStyle.verticalAlign
  const decorations = (textDecoration || "").split(" ")

  // [declared by this span?, value matches the format?, format name, resettable?]
  // resettable = inherited CSS property whose reset value clears the format.
  const rules = [
    [Boolean(fontWeight), fontWeight === "700" || fontWeight === "bold", "bold", true],
    [Boolean(textDecoration), decorations.includes("line-through"), "strikethrough", false],
    [Boolean(fontStyle), fontStyle === "italic", "italic", true],
    [Boolean(textDecoration), decorations.includes("underline"), "underline", false],
    [Boolean(verticalAlign), verticalAlign === "sub", "subscript", false],
    [Boolean(verticalAlign), verticalAlign === "super", "superscript", false]
  ]

  let decided = decidedFormats.get(node)
  rules.forEach(([declared, shouldApply, format, resettable]) => {
    if (decided && decided.has(format)) return
    if (shouldApply && !node.hasFormat(format)) {
      node.toggleFormat(format)
    } else if (resettable && declared && !shouldApply && node.hasFormat(format)) {
      // Explicit reset (font-weight:normal / font-style:normal) clears a format
      // an ancestor tag or converter already applied.
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

// Style properties that become Lexical text FORMATS (applied via
// applyTextFormatFromStyle), so they must NOT also be carried in the node's
// style string — that would double-represent bold/italic/etc. `white-space` is
// Lexical's own exportDOM artifact (stamped on every span), not user intent, so
// it is dropped too.
const NON_CARRIED_STYLE_PROPS = new Set([
  "font-weight",
  "font-style",
  "text-decoration",
  "vertical-align",
  "white-space"
])

// Every inline style declaration on the element that should be carried onto the
// text nodes it produces: ALL of them except the format-mapped props (which
// become Lexical formats) and Lexical's white-space artifact. This preserves
// color, background-color, font-size, font-family, text-transform,
// letter-spacing — and any future text-level style — instead of cherry-picking
// individual properties. It mirrors the full-style copy the removed positional
// collector did, so reopening pasted/legacy content keeps every styled
// attribute, not just color.
function carriedStyleDeclarations(domStyle) {
  const map = new Map()
  for (let i = 0; i < domStyle.length; i++) {
    const prop = domStyle.item(i)
    if (NON_CARRIED_STYLE_PROPS.has(prop)) continue
    map.set(prop, domStyle.getPropertyValue(prop))
  }
  return map
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

// `inherited` is the parent span's carried style declarations as a Map (color,
// background-color, font-size, font-family, … — see carriedStyleDeclarations).
// We MERGE rather than overwrite: a descendant text node that already carries
// its own declaration (from a deeper colored span converted first) keeps it —
// the inner value wins, matching CSS inheritance. The parent only fills in
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

// Custom HTML import for <span> that binds the span's inline style (color,
// background-color, font-size, … — everything except format props and
// white-space) to the text nodes it produces, at import time.
//
// Lexical's default span import (applyTextFormatFromStyle) only reads
// font-weight / font-style / text-decoration — it ignores color, background and
// every other non-format style. The editor used to compensate by collecting one
// style per DOM text node and re-applying them positionally to
// root.getAllTextNodes() after import. That drifts whenever Lexical's importer
// does not produce a 1:1, same-order mapping of DOM text nodes to lexical text
// nodes — and it frequently does not:
//   - TextNode.exportDOM stamps `white-space: pre-wrap` on every span, so on
//     re-import isNodePre() is true and a span's text is split on "\n"/"\t"
//     into multiple nodes (one DOM text node -> N lexical nodes).
//   - whitespace-only text nodes (e.g. newlines between block tags in
//     server-stored / Trix-migrated HTML) are dropped on import but still
//     counted by the collector.
// Any such mismatch shifts every subsequent style onto the wrong text node, so
// reopening the editor showed the color applied somewhere else (or lost).
//
// Binding the style during conversion keeps it attached to the right node
// regardless of how Lexical splits or drops surrounding text. We carry the
// span's FULL style set (not just color) so font-size / font-family /
// text-transform / letter-spacing survive reopen too — the positional collector
// copied the parent's whole style string, and cherry-picking individual
// properties here drops the rest.
//
// We still only take over when the span actually carries color/background:
// Lexical's default span conversion already handles a colorless span, so
// deferring there avoids changing behaviour for content this fix isn't about.
export function colorAwareSpanImport(domNode) {
  const { color, backgroundColor } = domNode.style
  if (!color && !backgroundColor) {
    // Defer to Lexical's default span conversion (format-from-style).
    return null
  }

  const inherited = carriedStyleDeclarations(domNode.style)

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
// DIRECT text-node children in a <span> carrying that element's FULL inline
// style, so the span importer binds it like any other span. We only push onto
// direct text children (matching the old immediate-parent semantics) — nested
// colored elements keep their own style and win via the merge in
// applyStyleToTextNodes. Run this AFTER syncLexicalStyleAttributes so
// data-lexical-* attributes are already materialized into inline style.
//
// The wrapper copies the element's entire style string rather than selected
// properties: a block element can carry color plus arbitrary text styles — e.g.
// pasted <p style="color:red; font-weight:700; font-size:20px">. Lexical's
// default block conversion ignores those styles, and the old positional
// collector applied the parent's full style string to the text node, so cherry-
// picking would drop whatever properties we forgot. colorAwareSpanImport then
// decides what to keep as node style vs. apply as a format vs. drop (white-space),
// uniformly for spans and these wrappers — block-level declarations like
// text-align/margin ride along harmlessly on the (inline) wrapper and are
// re-exported on the text node's span, exactly as the positional collector left
// them; the block keeps its own style for paragraph-level alignment.
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
      span.setAttribute("style", element.getAttribute("style"))
      element.replaceChild(span, child)
      span.appendChild(child)
    })
  })
}
