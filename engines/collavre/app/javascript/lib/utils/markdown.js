import { marked } from 'marked'
import DOMPurify from 'dompurify'
import { addTableDownloadButtons } from './table_download'

// Prism syntax highlighting for ALL rendered code blocks. The Lexical editor
// highlights code with Prism (@lexical/code) and tags each token with a
// `lexical-token-*` class (see lib/editor/code_token_theme.js). Every other
// surface that renders a fenced block — the rendered creative description, the
// markdown-mode preview, and chat/comments — tokenizes with the SAME Prism
// instance, the SAME language components @lexical/code loads, and the SAME
// token→class map, so a code block looks identical everywhere. The shared
// code_languages module below registers the extra grammars @lexical/code omits
// (ruby, bash, …) on the same Prism singleton and resolves each block's language
// identically to the editor, so the tokenizers stay aligned.
import Prism from 'prismjs'
import 'prismjs/components/prism-clike'
import 'prismjs/components/prism-javascript'
import 'prismjs/components/prism-markup'
import 'prismjs/components/prism-markdown'
import 'prismjs/components/prism-c'
import 'prismjs/components/prism-css'
import 'prismjs/components/prism-objectivec'
import 'prismjs/components/prism-sql'
import 'prismjs/components/prism-powershell'
import 'prismjs/components/prism-python'
import 'prismjs/components/prism-rust'
import 'prismjs/components/prism-swift'
import 'prismjs/components/prism-typescript'
import 'prismjs/components/prism-java'
import 'prismjs/components/prism-cpp'
import { CODE_TOKEN_THEME } from '../editor/code_token_theme'
import { detectCodeLanguage, normalizeFenceLang } from '../editor/code_languages'

// We tokenize manually; stop Prism from auto-highlighting `code[class*=language-]`
// on DOMContentLoaded (which would double-process comment code blocks).
Prism.manual = true

// Sanitize language identifier to prevent class attribute injection
function sanitizeLang(lang) {
  if (!lang) return ''
  return lang.replace(/[^a-zA-Z0-9_-]/g, '')
}

// `breaks: true` so a single newline renders as <br> (GitHub/Slack style),
// matching the canonical markdown_source where consecutive rich-editor lines are
// stored one-per-line instead of separated by a blank line. Applies app-wide
// (creative descriptions and comments) so a line break always means a line break.
marked.use({ breaks: true })

// Custom renderer for code blocks with syntax highlighting + mermaid
marked.use({
  renderer: {
    code({ text, lang }) {
      const safeLang = sanitizeLang(lang)
      if (safeLang === 'mermaid') {
        const escaped = text.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;')
        return `<div class="mermaid-chart">${escaped}</div>`
      }
      // Highlight with the SAME Prism engine + `lexical-token-*` classes the
      // editor and rendered creative description use (see highlightToLexicalHtml),
      // so a fenced block is colored identically across the markdown-mode preview,
      // chat/comments, the editor, and the rendered creative — one engine, one
      // palette. An explicit fence language is honored verbatim (matching the
      // editor); only genuinely unlabeled blocks are content-detected.
      const resolved = safeLang ? normalizeFenceLang(safeLang) : detectCodeLanguage(text, '')
      const highlighted = highlightToLexicalHtml(text, resolved)
      const langAttr = resolved ? ` lang="${resolved}"` : ''
      const codeClass = resolved ? ` class="language-${resolved}"` : ''
      return `<pre${langAttr}><code${codeClass}>${highlighted}</code></pre>`
    }
  }
})

// Allow the shared Prism `lexical-token-*` span classes through DOMPurify
DOMPurify.addHook('uponSanitizeAttribute', (node, data) => {
  if (node.tagName === 'SPAN' && data.attrName === 'class') {
    const classes = data.attrValue.split(/\s+/)
    // `lexical-token-*` is the single token-class family every surface now emits
    // (editor, rendered creative, markdown preview, comments) so they highlight
    // identically.
    const safe = classes.filter(c => c.startsWith('lexical-token-'))
    if (safe.length > 0) {
      data.attrValue = safe.join(' ')
      data.forceKeepAttr = true
    }
  }
  // Allow language-* classes on code elements (the language hint Prism reads)
  if (node.tagName === 'CODE' && data.attrName === 'class') {
    const classes = data.attrValue.split(/\s+/)
    const safe = classes.filter(c => c.startsWith('language-'))
    if (safe.length > 0) {
      data.attrValue = safe.join(' ')
      data.forceKeepAttr = true
    }
  }
  // Allow mermaid-chart class on div elements
  if (node.tagName === 'DIV' && data.attrName === 'class') {
    const classes = data.attrValue.split(/\s+/)
    if (classes.includes('mermaid-chart')) {
      data.attrValue = 'mermaid-chart'
      data.forceKeepAttr = true
    }
  }
})

const PURIFY_CONFIG = {
  ADD_ATTR: ['class'],
  ADD_TAGS: ['span']
}

function sanitize(html) {
  return DOMPurify.sanitize(html, PURIFY_CONFIG)
}

export function renderMarkdown(html) {
  return sanitize(marked.parse(html))
}

export function renderMarkdownInline(html) {
  return sanitize(marked.parseInline(html))
}

export function renderCommentMarkdown(text) {
  const content = text || ''
  const useBlock = content.includes('\n') || content.includes('```')
  const html = useBlock ? marked.parse(content) : marked.parseInline(content)
  return sanitize(html.trim())
}

function escapeHtml(text) {
  return text
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
}

function wrapToken(text, type) {
  const cls = type ? CODE_TOKEN_THEME[type] : undefined
  if (!cls) return escapeHtml(text)
  // Mirror @lexical/code, which splits a token's text on newlines/tabs into
  // separate highlight nodes (the whitespace between them carries no token
  // class), so the rendered span structure matches the editor exactly — not
  // just the colors.
  return text
    .split(/(\n|\t)/)
    .map((piece) =>
      piece === '\n' || piece === '\t' || piece === ''
        ? escapeHtml(piece)
        : `<span class="${cls}">${escapeHtml(piece)}</span>`
    )
    .join('')
}

// Flatten a Prism token stream into `lexical-token-*` span HTML, mirroring how
// @lexical/code's registerCodeHighlighting assigns exactly ONE class (the
// nearest enclosing token type) to each leaf text node. `type` is the enclosing
// token type handed down to bare string leaves, so the rendered view tokenizes
// and classes identically to the editor.
function tokensToLexicalHtml(tokens, type) {
  let html = ''
  for (const token of tokens) {
    if (typeof token === 'string') {
      html += wrapToken(token, type)
    } else if (typeof token.content === 'string') {
      const leafType = token.type === 'prefix' && typeof token.alias === 'string'
        ? token.alias
        : token.type
      html += wrapToken(token.content, leafType)
    } else if (Array.isArray(token.content)) {
      html += tokensToLexicalHtml(token.content, token.type === 'unchanged' ? undefined : token.type)
    }
  }
  return html
}

function highlightToLexicalHtml(code, lang) {
  // No grammar (unlabeled / unsupported language) → render as plaintext rather
  // than forcing JavaScript, so a block we can't confidently classify isn't
  // mis-colored as JS.
  const grammar = lang ? Prism.languages[lang] : null
  if (!grammar) return escapeHtml(code)
  return tokensToLexicalHtml(Prism.tokenize(code, grammar), undefined)
}

// Re-tokenize server-rendered creative description code blocks with Prism.
//
// Creative descriptions are rendered server-side by commonmarker. We disable its
// built-in syntect highlighter (which bakes a fixed dark theme inline), so the
// stored HTML arrives as plain `<pre lang="ruby"><code>raw source</code></pre>`.
// This pass re-tokenizes that source with the SAME Prism instance, language set,
// and `lexical-token-*` token classes the editor uses, so edit mode and rendered
// mode are colored token-for-token identically (not just the same palette) and
// follow the light/dark theme via the shared `--syntax-*` variables.
//
// Reading `textContent` (not innerHTML) means legacy descriptions whose stored
// HTML still carries baked-in inline-styled spans get re-highlighted too — no
// data migration needed. Idempotent via the `data-hljs-highlighted` marker.
export function highlightCodeBlocks(container) {
  if (!container) return
  const blocks = container.querySelectorAll('pre code:not([data-hljs-highlighted])')
  blocks.forEach((code) => {
    const pre = code.closest('pre')
    let lang = sanitizeLang(pre && pre.getAttribute('lang'))
    if (!lang) {
      const match = /(?:^|\s)language-([\w-]+)/.exec(code.className || '')
      if (match) lang = sanitizeLang(match[1])
    }
    // Resolve the language the same way the editor does. In the rendered view the
    // language always comes from the stored source (a real fence / <pre lang>), so
    // an explicit label is honored verbatim — including "javascript" — exactly as
    // the editor honors an import-resolved language. Only genuinely unlabeled
    // blocks are content-detected. This keeps edit and view in lock-step; without
    // it the view would re-detect an explicit ```javascript to ruby while the
    // editor honored javascript, and the two would disagree.
    const resolved = lang ? normalizeFenceLang(lang) : detectCodeLanguage(code.textContent, '')
    // Build the markup ourselves with escaped text and only `lexical-token-*`
    // classes, then sanitize as defense-in-depth (DOMPurify keeps those spans
    // via the class hook and neutralizes anything unexpected).
    code.innerHTML = sanitize(highlightToLexicalHtml(code.textContent, resolved))
    code.dataset.hljsHighlighted = 'true'
    // Drop any baked-in inline background (e.g. syntect's dark `<pre style=…>`)
    // so the theme-aware --color-code-bg from code_highlight.css wins.
    if (pre) pre.removeAttribute('style')
  })
}

// Lazy-load mermaid and render diagrams in a container
let mermaidReady = false

export async function renderMermaidDiagrams(container) {
  const charts = container.querySelectorAll('.mermaid-chart:not([data-processed])')
  if (charts.length === 0) return
  const { default: mermaid } = await import('mermaid')
  if (!mermaidReady) {
    mermaid.initialize({ startOnLoad: false, securityLevel: 'strict' })
    mermaidReady = true
  }
  try {
    await mermaid.run({ nodes: Array.from(charts) })
  } catch (e) {
    console.warn('Mermaid rendering failed:', e)
  }
}

export function renderMarkdownInContainer(container) {
  container.querySelectorAll('.comment-content').forEach((element) => {
    if (element.dataset.rendered === 'true') return
    element.innerHTML = renderCommentMarkdown(element.textContent)
    element.dataset.rendered = 'true'
    addTableDownloadButtons(element)
  })
  renderMermaidDiagrams(container)
}
