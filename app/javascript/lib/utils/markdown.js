import { marked } from 'marked'

export function renderMarkdown(html) {
  return marked.parse(html)
}

export function renderMarkdownInline(html) {
  return marked.parseInline(html)
}

export function renderMarkdownInContainer(container) {
  container.querySelectorAll('.comment-content').forEach((element) => {
    if (element.dataset.rendered === 'true') return
    element.innerHTML = marked.parse(element.textContent)
    element.dataset.rendered = 'true'
  })
}
