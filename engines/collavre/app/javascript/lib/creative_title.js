// Keep the original title available to optional presentation integrations.
export function setCreativeTitle(element, snippet, creativeId) {
  element.textContent = snippet
  element.dataset.creativeId = creativeId || ''
  element.dataset.originalLabel = creativeId ? snippet : ''
  return snippet
}
