// Minimal stand-in for the server-rendered inline-editor template
// (collavre/creatives/_inline_edit_form.html.erb). initializeCreativeRowEditor()
// looks every one of these nodes up by id and binds to whichever ones exist, so
// any test that needs a live editor session has to put them on the page first.
//
// Not a *.test.js file, so Jest's testMatch skips it.
const BUTTON_IDS = [
  'inline-metadata-btn', 'inline-toggle-markdown', 'inline-move-up', 'inline-move-down',
  'inline-add', 'inline-level-down', 'inline-level-up', 'inline-archive', 'inline-delete',
  'inline-delete-with-children', 'inline-link', 'inline-unconvert', 'inline-unlink',
  'inline-close', 'inline-recommend-parent', 'metadata-popup-close', 'metadata-save-btn',
]
const HIDDEN_INPUT_IDS = [
  'inline-method', 'inline-creative-description', 'inline-content-type',
  'inline-markdown-editor', 'inline-markdown-source', 'inline-parent-id',
  'inline-before-id', 'inline-after-id', 'inline-child-id', 'inline-origin-id',
]
const DIV_IDS = ['markdown-editor-wrapper', 'markdown-preview', 'inline-progress-value', 'inline-save-status', 'metadata-popup']

export function buildEditorDom(container) {
  const template = document.createElement('div')
  template.id = 'inline-edit-form'
  template.style.display = 'none'

  const form = document.createElement('form')
  form.id = 'inline-edit-form-element'
  template.appendChild(form)

  HIDDEN_INPUT_IDS.forEach((id) => {
    const input = document.createElement('input')
    input.type = 'hidden'
    input.id = id
    form.appendChild(input)
  })
  const progress = document.createElement('input')
  progress.type = 'checkbox'
  progress.id = 'inline-creative-progress'
  form.appendChild(progress)

  const editorRoot = document.createElement('div')
  editorRoot.id = 'lexical-inline-editor'
  editorRoot.dataset.lexicalEditorRoot = ''
  form.appendChild(editorRoot)

  const markdownTextarea = document.createElement('textarea')
  markdownTextarea.id = 'markdown-editor-textarea'
  form.appendChild(markdownTextarea)
  const metadataTextarea = document.createElement('textarea')
  metadataTextarea.id = 'metadata-yaml-editor'
  form.appendChild(metadataTextarea)
  const suggestions = document.createElement('select')
  suggestions.id = 'parent-suggestions'
  form.appendChild(suggestions)

  BUTTON_IDS.forEach((id) => {
    const button = document.createElement('button')
    button.type = 'button'
    button.id = id
    form.appendChild(button)
  })
  DIV_IDS.forEach((id) => {
    const div = document.createElement('div')
    div.id = id
    form.appendChild(div)
  })

  container.appendChild(template)
  return template
}
