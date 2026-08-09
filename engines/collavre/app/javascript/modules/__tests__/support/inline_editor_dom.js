// Shared DOM scaffolding for the inline row editor tests.
//
// initializeCreativeRowEditor() walks a large, fixed set of element ids that
// the ERB renders (see _inline_edit_form.html.erb) and bails out on the first
// missing one, so every suite that drives the real module needs the same
// skeleton. It lives here rather than in one of the suites so the empty-state
// recovery and removal tests stay in sync with each other.
//
// Not matched by jest's testMatch (`**/__tests__/**/*.test.js`), so it is not
// collected as a suite of its own.

export const BUTTON_IDS = [
  'inline-metadata-btn', 'inline-toggle-markdown', 'inline-move-up', 'inline-move-down',
  'inline-add', 'inline-level-down', 'inline-level-up', 'inline-archive', 'inline-delete',
  'inline-delete-with-children', 'inline-link', 'inline-unconvert', 'inline-unlink',
  'inline-close', 'inline-recommend-parent', 'metadata-popup-close', 'metadata-save-btn',
]

export const HIDDEN_INPUT_IDS = [
  'inline-method', 'inline-creative-description', 'inline-content-type',
  'inline-markdown-editor', 'inline-markdown-source', 'inline-parent-id',
  'inline-before-id', 'inline-after-id', 'inline-child-id', 'inline-origin-id',
]

export const DIV_IDS = [
  'markdown-editor-wrapper', 'markdown-preview', 'inline-progress-value',
  'inline-save-status', 'metadata-popup',
]

export function buildEditorDom(container, {
  saveFailedMessage,
  archiveFailedMessage,
  restoreFailedMessage,
  createUrl = '/creatives',
  updateUrlTemplate = '/creatives/__CREATIVE_ID__',
} = {}) {
  const template = document.createElement('div')
  template.id = 'inline-edit-form'
  template.style.display = 'none'

  const form = document.createElement('form')
  form.id = 'inline-edit-form-element'
  form.action = createUrl
  form.dataset.createUrl = createUrl
  form.dataset.updateUrlTemplate = updateUrlTemplate
  // Mirrors the ERB: plain JS can't call `t()`, so the localized save-failure
  // message rides on the form's data-* attribute.
  if (saveFailedMessage) form.dataset.saveFailedMessage = saveFailedMessage
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
    if (id === 'inline-archive') {
      // Same reason as saveFailedMessage above: the archive/restore failure
      // strings are localized in the ERB and read back off the button.
      if (archiveFailedMessage) button.dataset.failureMessage = archiveFailedMessage
      if (restoreFailedMessage) button.dataset.restoreFailureMessage = restoreFailedMessage
    }
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

// The real <creative-tree-row> is a Lit component; the module only needs it to
// expose a `.creative-tree` child, which is what the browser component renders.
// A brand-new row has no `.creative-row` yet — that markup only appears after a
// successful save inserts it — so the stub deliberately omits it.
export function defineTreeRowStub() {
  if (customElements.get('creative-tree-row')) return
  customElements.define('creative-tree-row', class extends HTMLElement {
    connectedCallback() {
      if (this.querySelector('.creative-tree')) return
      const tree = document.createElement('div')
      tree.className = 'creative-tree'
      this.appendChild(tree)
    }
  })
}

// The markup `_empty_state.html.erb` renders as the sole child of #creatives,
// reduced to the parts the editor interacts with.
//
// The `data-creatives-empty-state` wrapper is what makes this a placeholder as far
// as `creative_tree_empty_state.js` is concerned — that module hides and restores
// the wrapper, not the card inside it — so the fixture has to carry it or the
// hide/restore calls silently find nothing. `index.html.erb` also emits a pristine
// copy in a `<template>` outside the container, which `restoreTreeEmptyState()`
// clones when the tree render has wiped the original away; mirror that here so the
// restore path is exercised as it is in the browser.
export function renderEmptyState() {
  const creatives = document.getElementById('creatives')
  const markup = `
    <div data-creatives-empty-state>
      <div class="creative-empty-state">
        <button type="button" class="new-root-creative-btn">Add</button>
      </div>
    </div>
  `
  creatives.innerHTML = markup

  document.getElementById('creatives-empty-state-template')?.remove()
  const template = document.createElement('template')
  template.id = 'creatives-empty-state-template'
  template.innerHTML = markup
  document.body.appendChild(template)

  return creatives.querySelector('[data-creatives-empty-state]')
}

// A row that already exists on the server, i.e. one that renders a
// `.creative-row` and carries a creative id.
export function appendExistingRow(id, container = document.getElementById('creatives')) {
  const rowComponent = document.createElement('creative-tree-row')
  rowComponent.setAttribute('creative-id', String(id))
  rowComponent.dataset.descriptionRawHtml = '<p>existing</p>'
  rowComponent.dataset.progressValue = '0'
  // The stub only renders its .creative-tree child once connected.
  container.appendChild(rowComponent)
  const tree = rowComponent.querySelector('.creative-tree')
  tree.id = `creative-${id}`
  tree.dataset.id = String(id)
  const row = document.createElement('div')
  row.className = 'creative-row'
  tree.appendChild(row)
  return { rowComponent, tree, row }
}

// Lets queued microtasks and the rAF-deferred finalizeSetup() in startNew() run.
export function flush() {
  return new Promise((resolve) => {
    requestAnimationFrame(() => setTimeout(resolve, 0))
  })
}
