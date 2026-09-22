/** @jest-environment jsdom */
import { applyInlineDataset, copyEditorIcons, initializeEditorForm, nextEditorTree } from '../creative_inline_dataset'

test('optional editor metadata preserves omissions and clears explicit nulls', () => {
  const row = document.createElement('div')
  applyInlineDataset(row, { origin_id: 1, content_type: 'markdown', markdown_source: 'body', markdown_editor: 'rich', creative_type: 'workflow' })
  expect({ ...row.dataset }).toEqual({ originId: '1', contentType: 'markdown', markdownSource: 'body', markdownEditor: 'rich', creativeType: 'workflow' })
  applyInlineDataset(row, { creative_type: null })
  expect(row.dataset.creativeType).toBe('')
  expect(row.dataset.markdownSource).toBe('body')
})

test('new rows inherit available editor icons', () => {
  const row = document.createElement('div'), source = document.createElement('div')
  copyEditorIcons(row, null)
  copyEditorIcons(row, source)
  source.dataset.editIconHtml = 'edit'
  source.dataset.editOffIconHtml = 'close'
  copyEditorIcons(row, source)
  expect(row.editIconHtml).toBe('edit')
  expect(row.dataset.editOffIconHtml).toBe('close')
})

test('editor setup records identity and navigation handles either boundary', () => {
  const form = document.createElement('form'), method = document.createElement('input')
  initializeEditorForm(form, method, { id: 7 })
  expect(form.dataset.creativeId).toBe('7')
  expect(method.value).toBe('patch')
  initializeEditorForm(form, null, { id: 8 })
  document.body.innerHTML = '<div class="creative-tree"></div><div class="creative-tree"></div>'
  const [first, second] = document.querySelectorAll('.creative-tree')
  expect(nextEditorTree(first, 1)).toBe(second)
  expect(nextEditorTree(second, 1)).toBeUndefined()
  expect(nextEditorTree(null, 1)).toBeNull()
})
