// Keep the original title available to optional presentation integrations.
export function setCreativeTitle(element, snippet, creativeId) {
  // Preserve live translated text nodes when reopening the same creative.
  if (creativeId && element.dataset.creativeId === String(creativeId) && element.dataset.originalLabel === snippet) return snippet
  element.textContent = snippet
  element.dataset.creativeId = creativeId || ''
  element.dataset.originalLabel = creativeId ? snippet : ''
  return snippet
}
