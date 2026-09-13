import { setRowDatasetValue } from './creative_row_editor_helpers'

const FIELDS = {
  origin_id: 'originId', content_type: 'contentType', markdown_source: 'markdownSource',
  markdown_editor: 'markdownEditor', creative_type: 'creativeType'
}

export function applyInlineDataset(row, data) {
  for (const [key, datasetKey] of Object.entries(FIELDS)) {
    if (Object.prototype.hasOwnProperty.call(data, key)) setRowDatasetValue(row, datasetKey, data[key] ?? '')
  }
}

export function copyEditorIcons(row, source) {
  if (!source) return
  for (const key of ['editIconHtml', 'editOffIconHtml']) {
    if (source.dataset[key]) {
      row.dataset[key] = source.dataset[key]
      row[key] = source.dataset[key]
    }
  }
}

export function initializeEditorForm(form, method, data) {
  form.action = `/creatives/${data.id}`
  if (method) method.value = 'patch'
  form.dataset.creativeId = data.id
}

export function nextEditorTree(currentTree, delta) {
  const trees = Array.from(document.querySelectorAll('.creative-tree'))
  const index = trees.indexOf(currentTree)
  return index < 0 ? null : trees[index + delta]
}
