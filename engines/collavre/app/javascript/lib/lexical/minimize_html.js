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
// `white-space: pre-wrap` is redundant: plain text wraps normally and code
// blocks preserve whitespace via the kept `.lexical-code-block` rule (which
// children inherit).
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

function stripRedundantStyle(el) {
  if (!el.hasAttribute("style")) return
  REDUNDANT_STYLE_PROPS.forEach((prop) => el.style.removeProperty(prop))
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
