import { $isElementNode, $isTextNode } from "lexical"

// Per text node, which format dimensions a nearer (more nested) span already
// decided this import. Child span `after` callbacks run before ancestors', so a
// nested span claims its dimensions first and ancestors must not override them.
const decidedFormats = new WeakMap()

// Replicates Lexical's (non-exported) inline-style format reading for <span>:
// font-weight / font-style / text-decoration / vertical-align. Pasted content
// (Google Docs, Word) carries bold/italic as inline styles, not <b>/<i> tags,
// so our custom span import must compose these formats with the color binding.
//
// Lexical only turns formats ON, so a nested reset (font-weight:normal) can't
// un-bold itself once an ancestor re-applies bold. We treat a dimension as
// decided by the FIRST (nearest) span that declares it at all, so the inner
// span owns it; an omitted declaration leaves it open to inherit from ancestors.
// For inherited CSS props (font-weight, font-style) a reset value also actively
// CLEARS a format an ancestor tag (<b>/<i>) already toggled. text-decoration /
// vertical-align stay add-only (they propagate additively in CSS).
function applyTextFormatFromStyle(node, domStyle) {
  const fontWeight = domStyle.fontWeight
  const textDecoration = domStyle.textDecoration
  const fontStyle = domStyle.fontStyle
  const verticalAlign = domStyle.verticalAlign
  const decorations = (textDecoration || "").split(" ")

  // [declared by this span?, value matches format?, format name, resettable?]
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
      node.toggleFormat(format) // explicit reset clears an ancestor's format
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

// The exact (property, value) pairs applyTextFormatFromStyle turns into a format
// or reset. Only these are kept OUT of the carried node style (carrying them too
// would double-represent the format). Value-aware on purpose: an unmapped value
// (font-weight:800, font-style:oblique, vertical-align:middle) must be carried
// as inline style or it's silently dropped on reopen.
const FORMAT_MAPPED_VALUES = {
  "font-weight": new Set(["700", "bold", "normal"]),
  "font-style": new Set(["italic", "normal"]),
  "vertical-align": new Set(["sub", "super"])
}

// text-decoration is dropped wholesale: its tokens become formats that Lexical
// re-exports as its own text-decoration, so a remainder token would collide.
// white-space is Lexical's exportDOM artifact, not user intent.
const DROPPED_STYLE_PROPS = new Set(["text-decoration", "white-space"])

// Every inline declaration to carry onto the produced text nodes: all of them
// except format-mapped values and the dropped props above. Preserves color,
// background, font-size/family, text-transform, etc. without cherry-picking,
// mirroring the full-style copy the removed positional collector did.
function carriedStyleDeclarations(domStyle) {
  const map = new Map()
  for (let i = 0; i < domStyle.length; i++) {
    const prop = domStyle.item(i)
    if (DROPPED_STYLE_PROPS.has(prop)) continue
    const value = domStyle.getPropertyValue(prop)
    const mapped = FORMAT_MAPPED_VALUES[prop]
    if (mapped && mapped.has(value)) continue
    map.set(prop, value)
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

// Merge (not overwrite) inherited declarations: a node that already carries its
// own value (from a deeper colored span converted first) keeps it — inner wins,
// matching CSS inheritance. The parent only fills in what's missing.
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

// Custom <span> import: binds the span's inline style (color, background, and
// every other non-format/non-white-space prop) to its text nodes AT IMPORT TIME.
// The editor used to re-apply collected styles positionally to
// root.getAllTextNodes(), which drifts whenever Lexical's importer doesn't map
// DOM text nodes 1:1 (white-space:pre-wrap splits on \n/\t; whitespace-only
// nodes are dropped). Binding during conversion keeps style on the right node.
//
// We only take over when the span carries color/background — Lexical's default
// conversion already handles colorless spans, so deferring avoids behavior change.
export function colorAwareSpanImport(domNode) {
  const { color, backgroundColor } = domNode.style
  if (!color && !backgroundColor) {
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

// colorAwareSpanImport only runs for <span>. Color on a non-span element (a
// colored <p>/<li>/<h1>, or a materialized data-lexical-color on a block) would
// be dropped, since Lexical's default block conversions ignore color. Before
// import (and AFTER syncLexicalStyleAttributes materializes data-lexical-*), wrap
// each colored non-span's direct text children in a span carrying its full style,
// so the span importer binds it. Nested colored elements keep their own style and
// win via the merge in applyStyleToTextNodes. Block-level props (text-align,
// margin) ride along harmlessly on the inline wrapper.
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
