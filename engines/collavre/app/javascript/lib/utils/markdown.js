import { marked } from 'marked'
import DOMPurify from 'dompurify'

export function renderMarkdown(html) {
  return DOMPurify.sanitize(marked.parse(html))
}

export function renderMarkdownInline(html) {
  return DOMPurify.sanitize(marked.parseInline(html))
}

export function renderCommentMarkdown(text) {
  const content = text || ''
  const useBlock = content.includes('\n') || content.includes('```')
  const html = useBlock ? marked.parse(content) : marked.parseInline(content)
  return DOMPurify.sanitize(html.trim())
}

export function renderMarkdownInContainer(container) {
  container.querySelectorAll('.comment-content').forEach((element) => {
    if (element.dataset.rendered === 'true') return
    element.innerHTML = renderCommentMarkdown(element.textContent)
    element.dataset.rendered = 'true'
  })
}
