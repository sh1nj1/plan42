export async function throwCommentListError(response, element) {
  let message = element.dataset.noPermissionText || 'No permission'
  try {
    const payload = await response.json()
    message = payload.error || message
  } catch (_error) {
    // Keep the fallback when the error body is not JSON.
  }
  throw new Error(message)
}

export function syncCommentListProgress(controller, response, { creativeId, superseded, pagination }) {
  if (superseded || pagination || creativeId !== controller.creativeId) return
  const { element } = controller
  if (String(creativeId) !== element.dataset.creativeId) return

  const progress = response.headers.get('X-Creative-Progress')
  const bar = element.querySelector('creative-header-progress')
  if (bar && progress !== null && !bar.hasAttribute('data-row-progress')) bar.value = Number(progress)
}
