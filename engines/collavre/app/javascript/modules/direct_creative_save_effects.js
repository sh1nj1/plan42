import { refreshFilteredProgress } from '../lib/creative_tree_invalidation'

export function finishDirectCreativeSave({ lexicalEditor, deleteAttachment, persistProgress }) {
  const deletedIds = lexicalEditor?.getDeletedAttachments?.() || []
  deletedIds.forEach(deleteAttachment)
  if (persistProgress) refreshFilteredProgress()
}
