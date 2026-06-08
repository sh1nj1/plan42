// Minimize the HTML that Lexical's `$generateHtmlFromNodes` produces before it
// is persisted as a creative description / comment body.
//
// Lexical emits verbose markup: every text node is wrapped in
// `<span style="white-space: pre-wrap;">`, bold/italic double-wrap as
// `<b><strong class="lexical-text-bold">`, and the whole document is nested in
// an extra `<div>` wrapper. None of that is needed once the content is rendered
// inside a `.creative-content` container.
//
// The goal (per product spec) is: a single line of text needs no markup at all,
// and styled regions keep a minimal `<span class="…">` / semantic tag. We only
// strip genuine redundancy — we never drop a tag or class that the renderer or
// the editor's re-import (`$generateNodesFromDOM`) relies on.

// Editor-only inline style declarations that carry no meaning once rendered.
// `white-space: pre-wrap` is usually redundant: plain text wraps normally and
// code blocks preserve whitespace via the kept `.lexical-code-block` rule (which
// children inherit). It is NOT redundant when the text carries significant
// whitespace (see `hasSignificantWhitespace`): the render container
// (`.creative-content`) has no `pre-wrap`, so dropping it would collapse runs of
// spaces / indentation that the user actually typed.
const REDUNDANT_STYLE_PROPS = ["white-space"]

// Editor-only attributes that never affect rendering of persisted content.
const REDUNDANT_ATTRS = ["spellcheck"]

// Same-format wrapper pairs Lexical emits as outer/inner duplicates. Either tag
// alone still conveys the format on re-import, so the attribute-less one can go.
const SAME_FORMAT_PAIRS = [
  ["b", "strong"],
  ["i", "em"]
]

function hasNoAttributes(el) {
  return el.attributes.length === 0
}

// Whitespace whose rendering changes once `white-space: pre-wrap` is dropped:
// a run of 2+ whitespace (collapses to one space) or a tab/newline/form-feed.
// A single leading/trailing space between inline runs renders fine without
// `pre-wrap`, so it is not significant and must not block minimization of the
// common case (e.g. the "Hello " before a bold word).
function hasSignificantWhitespace(text) {
  return /\s{2,}|[\t\n\r\f]/.test(text)
}

// Block-level tags terminate an inline formatting context: whitespace never
// combines across them, so the document-order scan below must not look past one.
const BLOCK_TAGS = new Set([
  "BODY", "DIV", "P", "H1", "H2", "H3", "H4", "H5", "H6", "UL", "OL", "LI",
  "BLOCKQUOTE", "PRE", "TABLE", "THEAD", "TBODY", "TR", "TD", "TH", "FIGURE", "HR"
])

function isBlock(node) {
  return node != null && node.nodeType === 1 && BLOCK_TAGS.has(node.tagName)
}

// The rendered character immediately adjacent to `el` in document order, within
// the same inline formatting context. `dir` is "previousSibling"/"nextSibling".
// Climbs out of inline wrappers (e.g. `<b><strong>`) so a space nested one level
// deep still sees its neighbour, but stops at a block edge (returns "").
function adjacentInlineChar(el, dir) {
  let node = el
  while (node && !node[dir]) {
    node = node.parentNode
    if (isBlock(node)) return ""
  }
  const sibling = node && node[dir]
  if (!sibling) return ""
  const text = sibling.textContent || ""
  return dir === "previousSibling" ? text.slice(-1) : text.charAt(0)
}

// Significant whitespace can straddle an inline formatting boundary: e.g. the
// live editor serializes a bolded " bar" as `foo ` + `<b><strong> bar</strong></b>`,
// where each node holds a single edge space. Dropping `pre-wrap` from both sides
// would collapse the pair to one space. Detect each side independently so the
// kept `pre-wrap` lands on BOTH elements and the run survives unambiguously.
function hasBoundarySignificantWhitespace(el) {
  const text = el.textContent || ""
  if (/^\s/.test(text) && /\s/.test(adjacentInlineChar(el, "previousSibling"))) {
    return true
  }
  if (/\s$/.test(text) && /\s/.test(adjacentInlineChar(el, "nextSibling"))) {
    return true
  }
  return false
}

function stripRedundantStyle(el) {
  if (!el.hasAttribute("style")) return
  const keepWhiteSpace =
    hasSignificantWhitespace(el.textContent) ||
    hasBoundarySignificantWhitespace(el)
  REDUNDANT_STYLE_PROPS.forEach((prop) => {
    if (prop === "white-space" && keepWhiteSpace) return
    el.style.removeProperty(prop)
  })
  if (el.style.length === 0 || !el.getAttribute("style")?.trim()) {
    el.removeAttribute("style")
  }
}

function isSameFormatPair(tagA, tagB) {
  const a = tagA.toLowerCase()
  const b = tagB.toLowerCase()
  return SAME_FORMAT_PAIRS.some(
    ([x, y]) => (a === x && b === y) || (a === y && b === x)
  )
}

function unwrap(el) {
  const parent = el.parentNode
  if (!parent) return
  while (el.firstChild) parent.insertBefore(el.firstChild, el)
  parent.removeChild(el)
}

// Depth-first cleanup: normalize attributes, then collapse redundant wrappers.
function cleanElement(el) {
  // Recurse first so inner redundancy is resolved before we inspect a parent.
  Array.from(el.children).forEach(cleanElement)

  if (el.tagName === "BODY") return

  REDUNDANT_ATTRS.forEach((attr) => el.removeAttribute(attr))
  stripRedundantStyle(el)

  const tag = el.tagName.toLowerCase()

  // Attribute-less <span> conveys nothing — unwrap it (plain text, link inner).
  if (tag === "span" && hasNoAttributes(el)) {
    unwrap(el)
    return
  }

  // Collapse Lexical's outer/inner duplicate format wrappers (e.g. <b><strong>).
  // Drop whichever element carries no attributes; the other keeps the format.
  const onlyChild =
    el.children.length === 1 && el.childNodes.length === 1 ? el.children[0] : null
  if (onlyChild && isSameFormatPair(tag, onlyChild.tagName)) {
    if (hasNoAttributes(el)) {
      unwrap(el)
    } else if (hasNoAttributes(onlyChild)) {
      unwrap(onlyChild)
    }
  }
}

const MEDIA_SELECTOR = "img, action-text-attachment, figure, [data-trix-attachment]"

// A single top-level paragraph is just a line of text — emit its inline content
// without the <p> wrapper. Structural blocks (headings, lists, quotes, code,
// multiple paragraphs) are left intact.
function unwrapSingleParagraph(root) {
  const blocks = Array.from(root.children)
  if (blocks.length === 1 && blocks[0].tagName === "P") {
    const paragraph = blocks[0]
    // An empty line (just a <br> / whitespace, no media) collapses to "" so the
    // stored value matches isHtmlEmpty and re-imports to a fresh paragraph.
    if (!paragraph.textContent.trim() && !paragraph.querySelector(MEDIA_SELECTOR)) {
      return ""
    }
    // A soft line break (<br>) inside the line must keep its <p> wrapper: a bare
    // top-level <br> cannot be re-grouped into a paragraph on re-import and would
    // break the document shape / split the line.
    if (paragraph.querySelector("br")) {
      return root.innerHTML
    }
    return paragraph.innerHTML
  }
  return root.innerHTML
}

// `root` is the element whose children are the serialized content blocks
// (i.e. the throwaway <div> wrapper Lexical's output was parsed into). Mutates
// `root` in place and returns the minimized HTML string.
export function minimizeContentHtml(root) {
  if (!root) return ""
  Array.from(root.children).forEach(cleanElement)
  return unwrapSingleParagraph(root)
}
