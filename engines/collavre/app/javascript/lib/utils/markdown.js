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

// Custom renderer for code blocks with syntax highlighting
marked.use({
  renderer: {
    code({ text, lang }) {
      const safeLang = sanitizeLang(lang)
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
    const safe = classes.filter(c => c.startsWith('hljs-'))
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

export function renderMarkdownInContainer(container) {
  container.querySelectorAll('.comment-content').forEach((element) => {
    if (element.dataset.rendered === 'true') return
    element.innerHTML = renderCommentMarkdown(element.textContent)
    element.dataset.rendered = 'true'
    addTableDownloadButtons(element)
  })
}
