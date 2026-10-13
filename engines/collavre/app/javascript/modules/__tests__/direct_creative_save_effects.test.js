import { jest } from '@jest/globals'
import { finishDirectCreativeSave } from '../direct_creative_save_effects'

test.each([null, {}, { getDeletedAttachments: () => null }])('handles an editor without deleted attachments', lexicalEditor => {
  const deleteAttachment = jest.fn()
  finishDirectCreativeSave({ lexicalEditor, deleteAttachment, persistProgress: false })
  expect(deleteAttachment).not.toHaveBeenCalled()
})

test('deletes attachments captured by the successful direct save', () => {
  const deleteAttachment = jest.fn()
  finishDirectCreativeSave({ lexicalEditor: { getDeletedAttachments: () => [3, 7] }, deleteAttachment, persistProgress: false })
  expect(deleteAttachment.mock.calls.map(([id]) => id)).toEqual([3, 7])
})
