import { marked } from 'marked'

export function renderMarkdown(html) {
  return marked.parse(html)
}

export function renderMarkdownInline(html) {
  return marked.parseInline(html)
}

export function renderCommentMarkdown(text) {
  const content = text || ''
  const html = content.includes('\n') ? marked.parse(content) : marked.parseInline(content)
  return html.trim()
}

export function renderMarkdownInContainer(container) {
  container.querySelectorAll('.comment-content').forEach((element) => {
    if (element.dataset.rendered === 'true') return
    element.innerHTML = renderCommentMarkdown(element.textContent)
    element.dataset.rendered = 'true'
  })
}
