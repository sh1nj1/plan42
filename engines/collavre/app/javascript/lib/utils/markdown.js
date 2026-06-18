import { marked } from 'marked'
import DOMPurify from 'dompurify'
import { addTableDownloadButtons } from './table_download'
import hljs from 'highlight.js/lib/core'

// Register only commonly used languages to keep the bundle small
import javascript from 'highlight.js/lib/languages/javascript'
import typescript from 'highlight.js/lib/languages/typescript'
import ruby from 'highlight.js/lib/languages/ruby'
import python from 'highlight.js/lib/languages/python'
import css from 'highlight.js/lib/languages/css'
import xml from 'highlight.js/lib/languages/xml'
import json from 'highlight.js/lib/languages/json'
import yaml from 'highlight.js/lib/languages/yaml'
import bash from 'highlight.js/lib/languages/bash'
import sql from 'highlight.js/lib/languages/sql'
import markdownLang from 'highlight.js/lib/languages/markdown'
import diff from 'highlight.js/lib/languages/diff'
import erb from 'highlight.js/lib/languages/erb'
import go from 'highlight.js/lib/languages/go'
import java from 'highlight.js/lib/languages/java'
import plaintext from 'highlight.js/lib/languages/plaintext'

// Prism syntax highlighting for rendered creative code blocks. The Lexical
// editor highlights code with Prism (@lexical/code) and tags each token with a
// `lexical-token-*` class (see lib/editor/code_token_theme.js). To make the
// rendered creative byte-for-byte identical to edit mode, the view re-tokenizes
// with the SAME Prism instance, the SAME language components @lexical/code
// loads, and the SAME token→class map. The shared code_languages module below
// registers the extra grammars @lexical/code omits (ruby, bash, …) on the same
// Prism singleton and resolves each block's language identically to the editor,
// so the two tokenizers stay aligned. (highlight.js is still used for comment
// rendering below, a separate surface.)
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

hljs.registerLanguage('javascript', javascript)
hljs.registerLanguage('js', javascript)
hljs.registerLanguage('typescript', typescript)
hljs.registerLanguage('ts', typescript)
hljs.registerLanguage('ruby', ruby)
hljs.registerLanguage('rb', ruby)
hljs.registerLanguage('python', python)
hljs.registerLanguage('py', python)
hljs.registerLanguage('css', css)
hljs.registerLanguage('html', xml)
hljs.registerLanguage('xml', xml)
hljs.registerLanguage('json', json)
hljs.registerLanguage('yaml', yaml)
hljs.registerLanguage('yml', yaml)
hljs.registerLanguage('bash', bash)
hljs.registerLanguage('sh', bash)
hljs.registerLanguage('shell', bash)
hljs.registerLanguage('sql', sql)
hljs.registerLanguage('markdown', markdownLang)
hljs.registerLanguage('md', markdownLang)
hljs.registerLanguage('diff', diff)
hljs.registerLanguage('erb', erb)
hljs.registerLanguage('go', go)
hljs.registerLanguage('java', java)
hljs.registerLanguage('plaintext', plaintext)
hljs.registerLanguage('text', plaintext)

function highlightCode(code, lang) {
  if (lang && hljs.getLanguage(lang)) {
    try {
      return hljs.highlight(code, { language: lang }).value
    } catch (_) { /* fall through */ }
  }
  // Auto-detect for unlabeled code blocks
  try {
    return hljs.highlightAuto(code).value
  } catch (_) {
    return code
  }
}

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
      const highlighted = highlightCode(text, safeLang)
      const langClass = safeLang ? ` language-${safeLang}` : ''
      return `<pre><code class="hljs${langClass}">${highlighted}</code></pre>`
    }
  }
})

// Allow hljs span classes through DOMPurify
DOMPurify.addHook('uponSanitizeAttribute', (node, data) => {
  if (node.tagName === 'SPAN' && data.attrName === 'class') {
    const classes = data.attrValue.split(/\s+/)
    // hljs-* for comment code blocks, lexical-token-* for rendered creative
    // descriptions (which now share the editor's Prism token classes).
    const safe = classes.filter(c => c.startsWith('hljs-') || c.startsWith('lexical-token-'))
    if (safe.length > 0) {
      data.attrValue = safe.join(' ')
      data.forceKeepAttr = true
    }
  }
  // Allow hljs and language-* classes on code elements
  if (node.tagName === 'CODE' && data.attrName === 'class') {
    const classes = data.attrValue.split(/\s+/)
    const safe = classes.filter(c => c === 'hljs' || c.startsWith('language-'))
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
