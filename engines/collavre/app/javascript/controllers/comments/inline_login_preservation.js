// Keep an in-progress login in the DOM while the same chat list refreshes.
// Nothing is copied into browser storage; removing the card drops its input.
export function replaceCommentsPreservingLogins(container, html, topicId) {
  const template = document.createElement("template")
  template.innerHTML = html
  container.querySelectorAll('turbo-frame[id^="inline_agent_login_"]').forEach((frame) => {
    const replacement = template.content.querySelector(`#${CSS.escape(frame.id)}`)
    if (replacement && loginSource(replacement) === loginSource(frame)) {
      replacement.replaceWith(frame)
    }
  })
  container.replaceChildren(template.content)
  container.dataset.currentTopicId = topicId || ""
}

function loginSource(frame) {
  return new URL(frame.getAttribute("src"), document.baseURI).href
}
