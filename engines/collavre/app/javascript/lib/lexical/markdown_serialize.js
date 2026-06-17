import { $isTextNode, $isParagraphNode } from "lexical"
import { $convertToMarkdownString, TRANSFORMERS } from "@lexical/markdown"

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

// A paragraph the user left blank (pressed Enter on an empty line). Decorator-
// or text-bearing paragraphs are NOT blank, so media and whitespace-with-content
// keep their normal export.
function isBlankParagraph(node) {
  if (!$isParagraphNode(node)) return false
  return node.getChildren().every((child) => $isTextNode(child) && !child.getTextContent().trim())
}

// Blank paragraphs -> a non-breaking-space line (U+00A0). The default export
// collapses an empty paragraph to "" (indistinguishable from the blank line the
// upstream join inserts between two normal paragraphs), so collapseParagraphBreaks
// would erase a deliberately-typed empty line. A NBSP line is non-blank Markdown,
// so the hard-break renderer keeps it as a visible empty line inside one <p>
// instead of collapsing it — and N empty paragraphs render as N blank lines.
const EMPTY_PARAGRAPH_TRANSFORMER = exportOnlyTransformer(
  (node) => (isBlankParagraph(node) ? "\u00A0" : null),
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
  DECORATOR_ELEMENT_TRANSFORMER,
  EMPTY_PARAGRAPH_TRANSFORMER,
  DECORATOR_TEXT_TRANSFORMER,
  COLOR_TRANSFORMER,
  ...TRANSFORMERS
]

// A block that must keep a blank line before/after it (i.e. is NOT a plain
// paragraph): heading, blockquote, list item, fenced code, table row, thematic
// break, or a top-level media tag. Anything else is treated as paragraph text.
const NON_PARAGRAPH_LEAD =
  /^(?:#{1,6}\s|>|[-*+]\s|\d+[.)]\s|`{3,}|~{3,}|\||<(?:img|video|a)\b|(?:-{3,}|\*{3,}|_{3,})\s*$)/

// Fenced code blocks may legitimately contain blank lines; guard them so the
// paragraph collapse below never joins lines inside a code sample.
const FENCE_BLOCK = /(`{3,}|~{3,})[^\n]*\n[\s\S]*?\n\1[ \t]*(?=\n|$)/g

function isPlainParagraph(block) {
  if (!block || block.includes("\x00MDFENCE")) return false
  return !NON_PARAGRAPH_LEAD.test(block.split("\n", 1)[0])
}

// Collapse the blank line between two consecutive plain paragraphs so multi-line
// rich text serializes as `a\nb` instead of `a\n\nb`. The renderers run with
// hard breaks (a single `\n` becomes <br>), so the visual line break is
// preserved while markdown_source stays free of the inserted blank line the user
// never typed. Headings, lists, quotes, code fences, tables and media keep their
// standard blank-line separation.
export function collapseParagraphBreaks(markdown) {
  // A document made only of blank paragraphs (each now a U+00A0 line) carries no
  // real content — keep it empty so the empty-state contract (placeholders,
  // description presence) is unchanged. trim() drops the nbsp too.
  if (!String(markdown).trim()) return ""

  const fences = []
  const guarded = String(markdown).replace(FENCE_BLOCK, (match) => {
    fences.push(match)
    return `\x00MDFENCE${fences.length - 1}\x00`
  })

  const blocks = guarded.split("\n\n")
  let out = blocks.length ? blocks[0] : ""
  for (let i = 1; i < blocks.length; i++) {
    const join = isPlainParagraph(blocks[i - 1]) && isPlainParagraph(blocks[i]) ? "\n" : "\n\n"
    out += join + blocks[i]
  }

  return out.replace(/\x00MDFENCE(\d+)\x00/g, (_, n) => fences[Number(n)])
}

// Read the editor state and return canonical Markdown.
export function lexicalToMarkdown(editor) {
  let markdown = ""
  editor.getEditorState().read(() => {
    markdown = $convertToMarkdownString(MARKDOWN_TRANSFORMERS)
  })
  return collapseParagraphBreaks(markdown)
}
