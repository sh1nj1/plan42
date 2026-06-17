import { $isTextNode } from "lexical"
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
  return `<span style="${decls.join("; ")}">${inner}</span>`
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

// Boilerplate so a TextMatchTransformer can be export-only: import never fires.
const NEVER = /(?!)/

function exportOnlyTransformer(exportFn, dependencies = []) {
  return {
    dependencies,
    export: exportFn,
    importRegExp: NEVER,
    regExp: NEVER,
    replace: () => false,
    trigger: "",
    type: "text-match"
  }
}

// Colored / highlighted text -> normalized <span>. Falls through (returns null)
// for uncolored text so the default text-format export still applies.
const COLOR_TRANSFORMER = exportOnlyTransformer((node, _exportChildren, exportFormat) => {
  if (!$isTextNode(node)) return null
  const style = node.getStyle ? node.getStyle() : ""
  if (!style) return null
  return colorSpanMarkup(style, exportFormat(node, node.getTextContent()))
})

// Decorator nodes -> raw HTML. Duck-typed via getType() so this module stays
// free of the .jsx node classes (kept importable under native-ESM Jest).
const DECORATOR_TRANSFORMER = exportOnlyTransformer((node) => {
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
})

// Our custom text-match transformers run first so colored text and decorator
// nodes are claimed before the upstream defaults (which would drop their style).
export const MARKDOWN_TRANSFORMERS = [DECORATOR_TRANSFORMER, COLOR_TRANSFORMER, ...TRANSFORMERS]

// Read the editor state and return canonical Markdown.
export function lexicalToMarkdown(editor) {
  let markdown = ""
  editor.getEditorState().read(() => {
    markdown = $convertToMarkdownString(MARKDOWN_TRANSFORMERS)
  })
  return markdown
}
