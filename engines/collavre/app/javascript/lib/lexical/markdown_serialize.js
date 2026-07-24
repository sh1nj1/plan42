import {
  $isTextNode,
  $isParagraphNode,
  $isLineBreakNode,
  $createParagraphNode
} from "lexical"
import { $convertToMarkdownString, TRANSFORMERS } from "@lexical/markdown"
import { TABLE, setCellTransformers } from "./table_transformer"

// Serializes the Lexical editor state to Markdown as the canonical storage
// format. Standard block/inline features (headings, lists, quotes, code,
// bold/italic/strikethrough, inline code, links) round-trip through Markdown
// via the upstream TRANSFORMERS. Features Markdown can't express are emitted as
// a SMALL, FIXED set of normalized inline HTML fragments:
//
//   - text color / background-color  -> <span style="...">
//   - images / videos / attachments  -> raw <img>/<video>/<a download> tags
//
// The HTML shape is normalized (one canonical form per feature) and the CSS
// values are validated, so the server-side sanitizer can safelist exactly these
// and the import path (markdown -> HTML -> Lexical) reconstructs them losslessly.

// Only these CSS color values are allowed inside an emitted <span>. Anything
// else (url(), expression(), javascript:, <, >) is dropped so a crafted inline
// style can't smuggle script or external requests into stored Markdown.
const SAFE_COLOR_VALUE =
  /^(#[0-9a-fA-F]{3,8}|rgba?\([0-9.,%\s]+\)|hsla?\([0-9.,%\s]+\)|var\(--[a-zA-Z0-9-_]+\)|[a-zA-Z]+)$/

function safeColorValue(value) {
  if (!value) return null
  const v = value.trim().replace(/;+$/, "").trim()
  if (!v) return null
  if (/url\(|expression|javascript:|@import|[<>]/i.test(v)) return null
  return SAFE_COLOR_VALUE.test(v) ? v : null
}

function colorBgFromStyle(styleText) {
  let color = null
  let background = null
  ;(styleText || "").split(";").forEach((decl) => {
    const idx = decl.indexOf(":")
    if (idx === -1) return
    const key = decl.slice(0, idx).trim().toLowerCase()
    const value = decl.slice(idx + 1)
    if (key === "color") color = safeColorValue(value)
    else if (key === "background-color") background = safeColorValue(value)
  })
  return { color, background }
}

function escapeHtmlAttr(value) {
  return String(value == null ? "" : value)
    .replace(/&/g, "&amp;")
    .replace(/"/g, "&quot;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
}

function escapeHtmlText(value) {
  return String(value == null ? "" : value)
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
}

// Wrap already-formatted inner Markdown text in a normalized colored <span>, or
// return null when the style carries no (safe) color/background. The declaration
// order is fixed (color first) so the same selection always serializes to the
// same bytes — line-diff/snapshot stability depends on this.
export function colorSpanMarkup(styleText, inner) {
  const { color, background } = colorBgFromStyle(styleText)
  if (!color && !background) return null
  const decls = []
  if (color) decls.push(`color: ${color}`)
  if (background) decls.push(`background-color: ${background}`)
  // `inner` is the Markdown-formatted text of a colored node. Lexical's export
  // escapes Markdown punctuation but NOT HTML metacharacters, so colored text
  // like `<foo>` would become raw markup inside the <span> and get reinterpreted
  // (and stripped) by the Markdown renderer/sanitizer. Escape <, >, & so user
  // text stays text. Markdown syntax chars (*, _, `, ~) are left untouched.
  return `<span style="${decls.join("; ")}">${escapeHtmlText(inner)}</span>`
}

// Canonical inline HTML for the decorator nodes, matching the shapes the import
// path (markdown_to_html -> $generateNodesFromDOM) and the server sanitizer
// expect. Numeric width/height only — Lexical's "inherit" sentinel is dropped.
export function imageMarkup({ src, altText, width, height }) {
  let html = `<img src="${escapeHtmlAttr(src)}" alt="${escapeHtmlAttr(altText)}"`
  if (Number.isFinite(Number(width)) && Number(width) > 0) {
    html += ` width="${escapeHtmlAttr(width)}"`
  }
  if (Number.isFinite(Number(height)) && Number(height) > 0) {
    html += ` height="${escapeHtmlAttr(height)}"`
  }
  return `${html}>`
}

export function videoMarkup({ src }) {
  return `<video controls src="${escapeHtmlAttr(src)}"></video>`
}

export function attachmentMarkup({ src, filename, filesize }) {
  let html = `<a href="${escapeHtmlAttr(src)}" download="${escapeHtmlAttr(filename)}"`
  if (filesize != null && filesize !== "") {
    html += ` data-filesize="${escapeHtmlAttr(filesize)}"`
  }
  return `${html}>${escapeHtmlText(filename)}</a>`
}

// Boilerplate so a transformer can be export-only: import never fires.
const NEVER = /(?!)/

function exportOnlyTransformer(exportFn, { dependencies = [], type = "text-match" } = {}) {
  return {
    dependencies,
    export: exportFn,
    importRegExp: NEVER,
    regExp: NEVER,
    replace: () => false,
    trigger: "",
    type
  }
}

// Decorator nodes -> raw HTML. Duck-typed via getType() so this module stays
// free of the .jsx node classes (kept importable under native-ESM Jest).
function decoratorMarkup(node) {
  const type = node.getType ? node.getType() : null
  if (type === "image") {
    return imageMarkup({
      src: node.getSrc?.(),
      altText: node.getAltText?.(),
      width: node.__width,
      height: node.__height
    })
  }
  if (type === "video") {
    return videoMarkup({ src: node.getSrc?.() })
  }
  if (type === "attachment") {
    return attachmentMarkup({
      src: node.getSrc?.(),
      filename: node.getFilename?.(),
      filesize: node.__filesize
    })
  }
  return null
}

// A paragraph the user left blank: it carries no real text, only empty text
// nodes and/or line breaks. (Decorator- or text-bearing paragraphs are NOT
// blank, so media and real content keep their normal export.) An empty
// paragraph from pressing Enter has zero children; a run of blank lines that
// was reopened comes back as ONE paragraph holding N LineBreakNodes (the
// importer groups consecutive <br> markers together).
function isBlankParagraph(node) {
  if (!$isParagraphNode(node)) return false
  // A blank paragraph inside a table cell is just an empty cell — it must stay
  // empty (`|  |`), not become a `<br>`. The cell serializer reuses this
  // transformer set, so exclude paragraphs nested in a cell (duck-typed by type
  // to keep this module free of the @lexical/table import).
  const parent = node.getParent ? node.getParent() : null
  if (parent && parent.getType && parent.getType() === "tablecell") return false
  return node
    .getChildren()
    .every((child) => $isLineBreakNode(child) || ($isTextNode(child) && !child.getTextContent().trim()))
}

// How many blank lines a blank paragraph represents: one per LineBreakNode, but
// at least one (a freshly-typed empty paragraph has no line breaks yet still
// stands for a single blank line). This exact count is what keeps multiple
// blank lines from multiplying on every save — the reopened paragraph holds N
// line breaks and must re-emit N markers, not N+1.
function blankParagraphBreakCount(node) {
  const breaks = node.getChildren().filter($isLineBreakNode).length
  return Math.max(1, breaks)
}

// Blank paragraphs -> one `<br>` per blank line. A `<br>` is a semantic empty
// line (not a stray space or NBSP): the hard-break renderers keep it as a
// visible blank line, and because each marker sits in its own block separated
// by the standard `\n\n`, a blank line after a list no longer gets pulled into
// the last <li> via lazy continuation. Round-trips: the importer regroups the
// rendered <br> elements into a blank paragraph that re-exports identically.
const BLANK_PARAGRAPH_TRANSFORMER = exportOnlyTransformer(
  (node) =>
    isBlankParagraph(node) ? Array(blankParagraphBreakCount(node)).fill("<br>").join("\n\n") : null,
  { type: "element" }
)

// Colored / highlighted text -> normalized <span>. Falls through (returns null)
// for uncolored text so the default text-format export still applies.
const COLOR_TRANSFORMER = exportOnlyTransformer((node, _exportChildren, exportFormat) => {
  if (!$isTextNode(node)) return null
  const style = node.getStyle ? node.getStyle() : ""
  if (!style) return null
  return colorSpanMarkup(style, exportFormat(node, node.getTextContent()))
})

// Decorator handler registered as a TEXT-MATCH transformer for media that lives
// INLINE inside a paragraph (claimed during exportChildren).
const DECORATOR_TEXT_TRANSFORMER = exportOnlyTransformer((node) => decoratorMarkup(node))

// The SAME handler registered as an ELEMENT transformer for media that is a
// direct child of the root (the upload plugin's no-selection append path, and
// imported block-level <img> nodes). $convertToMarkdownString only runs element
// transformers on top-level nodes — a top-level decorator that matches no element
// transformer falls back to DecoratorNode#getTextContent() (empty for media),
// silently dropping it from markdown_source. Without this, the first rich save
// loses every top-level image/video/file.
const DECORATOR_ELEMENT_TRANSFORMER = exportOnlyTransformer((node) => decoratorMarkup(node), {
  type: "element"
})

// Our custom transformers run first so colored text and decorator nodes are
// claimed before the upstream defaults (which would drop their style/content).
export const MARKDOWN_TRANSFORMERS = [
  TABLE,
  DECORATOR_ELEMENT_TRANSFORMER,
  BLANK_PARAGRAPH_TRANSFORMER,
  DECORATOR_TEXT_TRANSFORMER,
  COLOR_TRANSFORMER,
  ...TRANSFORMERS
]

// Tables serialize their cell content with the same transformer set. Injected
// here (rather than imported into table_transformer.js) to break the cycle.
setCellTransformers(MARKDOWN_TRANSFORMERS)

// Fenced code blocks may legitimately contain consecutive blank lines; guard
// them so the blank-line normalization below never touches a code sample.
const FENCE_BLOCK = /(`{3,}|~{3,})[^\n]*\n[\s\S]*?\n\1[ \t]*(?=\n|$)/g

// Inline code spans (`...`) may legitimately contain the literal text `<br>` or
// a lone NBSP; guard them too so the blank-line normalization never rewrites the
// span (which would break it on save). Matched after fences are stashed, so the
// remaining backtick runs are genuine inline code.
const INLINE_CODE = /(`+)[^\n]*?\1/g

// Normalize the canonical Markdown projection. Enter produces a real paragraph
// break (standard `\n\n` separation); a blank line the user typed is preserved
// as a `<br>` marker (see BLANK_PARAGRAPH_TRANSFORMER). This pass only:
//   - returns "" for a document with no real content (only whitespace and/or
//     `<br>` markers), keeping the empty-state placeholder/presence contract,
//   - migrates legacy NBSP-only blank-line markers (pre-`<br>` content) to a
//     real `<br>` marker so they stop acting as a CommonMark lazy continuation,
//   - isolates every `<br>` marker as its own block,
//   - collapses runs of 3+ newlines to one blank line so block separation stays
//     canonical and the very first save is round-trip stable,
//   - trims trailing whitespace.
// Blank lines and literal `<br>`/NBSP inside code (fenced or inline) are
// preserved verbatim.
export function normalizeMarkdownBlankLines(markdown) {
  // A document of only blank lines (each now a `<br>`) carries no real content,
  // so strip the markers before the emptiness check.
  if (!String(markdown).replace(/<br\s*\/?>/gi, "").trim()) return ""

  const guards = []
  const stash = (match) => `\x00MDGUARD${guards.push(match) - 1}\x00`
  const guarded = String(markdown)
    .replace(FENCE_BLOCK, stash)
    .replace(INLINE_CODE, stash)

  const normalized = guarded
    // Legacy blank-line markers stored a line of only NBSP (U+00A0). CommonMark
    // treats NBSP as content — a lazy list continuation — re-introducing the
    // list-indent bug, so migrate such lines to a real `<br>` marker on save.
    // (A regular whitespace-only line is already a CommonMark blank line.)
    .replace(/^[ \t]*\u00A0[ \t\u00A0]*$/gm, "<br>")
    // Each blank-line marker is its own block: isolate every `<br>` with a blank
    // line on both sides. Lexical's exporter joins a freshly-typed empty
    // paragraph to its neighbours with a single `\n`, while a reopened (grouped)
    // blank paragraph gets `\n\n`; canonicalizing here makes the very first save
    // byte-identical to the reopen fixpoint regardless of which path produced it.
    // BLANK_PARAGRAPH_TRANSFORMER always emits a marker alone on its line, so we
    // only match a `<br>` that is the WHOLE line (anchored ^…$ under /m). A
    // `<br>` embedded in other content (an in-paragraph hard break or raw inline
    // HTML such as `<span>foo<br>bar</span>`) is not a marker and is left
    // untouched — isolating it would rewrite user HTML on save.
    .replace(/\n*^[ \t]*<br>[ \t]*$\n*/gm, "\n\n<br>\n\n")
    .replace(/\n{3,}/g, "\n\n")
    .replace(/^\n+/, "")
    .replace(/\s+$/, "")

  return normalized.replace(/\x00MDGUARD(\d+)\x00/g, (_, n) => guards[Number(n)])
}

// On reopen, a run of blank-line markers (<br>) comes back grouped into ONE
// paragraph holding N LineBreakNodes. Lexical renders such a paragraph as N+1
// visual lines — each break starts a new line on top of the paragraph's own
// line — so a single typed blank line reopens as TWO, growing by one on every
// reopen (the "blank lines keep multiplying" bug). Freshly typed blank lines are EMPTY
// paragraphs instead (zero children, one visual line each). Re-create that
// structure: replace every all-LineBreakNode paragraph with N empty paragraphs
// so reopened blank lines match typed ones. Export is unaffected — each empty
// paragraph still emits exactly one <br> (blankParagraphBreakCount), so the
// canonical Markdown round-trips byte-for-byte. Paragraphs that mix text with a
// break (real soft breaks) are left untouched.
export function splitBlankLineParagraphs(root) {
  if (!root || !root.getChildren) return
  root.getChildren().forEach((node) => {
    if (!$isParagraphNode(node)) return
    const children = node.getChildren()
    if (children.length === 0) return
    if (!children.every($isLineBreakNode)) return
    for (let i = 0; i < children.length; i++) {
      node.insertBefore($createParagraphNode())
    }
    node.remove()
  })
}

// Read the editor state and return canonical Markdown.
export function lexicalToMarkdown(editor) {
  let markdown = ""
  editor.getEditorState().read(() => {
    markdown = $convertToMarkdownString(MARKDOWN_TRANSFORMERS)
  })
  return normalizeMarkdownBlankLines(markdown)
}
