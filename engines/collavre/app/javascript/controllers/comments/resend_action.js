import { alertDialog } from '../../lib/utils/dialog'

function selectedOwnMessage(controller) {
  if (controller.selection.size !== 1) return null
  const id = Array.from(controller.selection)[0]
  const comment = document.getElementById(`comment_${id}`)
  const userId = document.body.dataset.currentUserId
  if (!userId || comment?.dataset.userId !== userId || comment.dataset.aiUser === 'true') return null
  if (comment.dataset.inboxSystem === 'true' || comment.dataset.commandMessage === 'true') return null
  return id
}

export function installResendAction(controller, bar) {
  const button = document.createElement('button')
  button.type = 'button'
  button.className = 'selection-action-bar-btn selection-action-resend'
  button.textContent = controller.element.dataset.resendLabel
  button.title = controller.element.dataset.resendDescription
  button.disabled = !selectedOwnMessage(controller) || !!controller.resendingComment
  button.addEventListener('click', (event) => {
    event.stopPropagation()
    resendSelectedMessage(controller, button)
  })
  bar.querySelector('.selection-action-bar-close').before(button)
}

export async function resendSelectedMessage(controller, button) {
  const id = selectedOwnMessage(controller)
  if (!id || controller.resendingComment) return
  const creativeId = controller.creativeId
  const topicId = controller.currentTopicId
  controller.resendingComment = true
  button.disabled = true
  try {
    const response = await fetch(`/creatives/${controller.creativeId}/comments/${id}/resend`, {
      method: 'POST',
      headers: { 'X-CSRF-Token': document.querySelector('meta[name=csrf-token]')?.content }
    })
    if (!response.ok) {
      const data = await response.json().catch(() => ({}))
      throw new Error(data.error || controller.element.dataset.resendFailed)
    }
    if (controller.creativeId !== creativeId || controller.currentTopicId !== topicId) return
    controller.clearSelection()
    controller.loadInitialComments()
  } catch (error) {
    alertDialog(error.message || controller.element.dataset.resendFailed)
  } finally {
    controller.resendingComment = false
    controller.updateSelectionActionBar()
  }
}

export function installSelectionActions(controller, bar) {
  installResendAction(controller, bar)
    bar.querySelector('.selection-action-delete').addEventListener('click', (e) => { e.stopPropagation(); controller.deleteSelectedComments() })
    bar.querySelector('.selection-action-merge').addEventListener('click', (e) => { e.stopPropagation(); controller.mergeSelectedComments() })
    bar.querySelector('.selection-action-move').addEventListener('click', (e) => controller.openMoveModal(e))
    bar.querySelector('.selection-action-topic').addEventListener('click', (e) => controller.openTopicSearchPopup(e))
    bar.querySelector('.selection-action-branch').addEventListener('click', (e) => { e.stopPropagation(); controller.branchSelectedComments() })
    bar.querySelector('.selection-action-bar-close').addEventListener('click', () => controller.clearSelection())
}
