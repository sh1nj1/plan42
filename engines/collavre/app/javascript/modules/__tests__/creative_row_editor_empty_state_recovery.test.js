/**
 * @jest-environment jsdom
 */
import { jest } from '@jest/globals'

// The real inline editor is a JSX module (untransformed in Jest), so it is
// stubbed. The delegated click handler stays REAL here: the empty-state Add
// button reaches startNew() through it, and hiding the empty-state card is part
// of that path.
const createInlineEditorMock = jest.fn()
const saveMock = jest.fn()

jest.unstable_mockModule('../lexical_inline_editor', () => ({
  createInlineEditor: createInlineEditorMock,
}))
jest.unstable_mockModule('../../lib/api/creatives', () => ({
  default: {
    save: saveMock,
    get: jest.fn(() => Promise.resolve({})),
    children: jest.fn(() => Promise.resolve([])),
  },
}))

const { initializeCreativeRowEditor } = await import('../creative_row_editor')

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

function buildEditorDom(container) {
  const template = document.createElement('div')
  template.id = 'inline-edit-form'
  template.style.display = 'none'

  const form = document.createElement('form')
  form.id = 'inline-edit-form-element'
  form.action = '/creatives'
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

// The real <creative-tree-row> is a Lit component; startNew() only needs it to
// expose a `.creative-tree` child, which is what the browser component renders.
// A brand-new row has no `.creative-row` yet — that markup only appears after a
// successful save inserts it — so the stub deliberately omits it.
function defineTreeRowStub() {
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

function renderEmptyState() {
  const creatives = document.getElementById('creatives')
  creatives.innerHTML = `
    <div class="creative-empty-state">
      <button type="button" class="new-root-creative-btn">Add</button>
    </div>
  `
  return creatives.querySelector('.creative-empty-state')
}

// Lets queued microtasks and the rAF-deferred finalizeSetup() in startNew() run.
function flush() {
  return new Promise((resolve) => {
    requestAnimationFrame(() => setTimeout(resolve, 0))
  })
}

describe('empty-state recovery when the first inline save fails', () => {
  beforeAll(() => {
    defineTreeRowStub()
    createInlineEditorMock.mockImplementation(() => ({
      destroy: jest.fn(),
      load: jest.fn(),
      focus: jest.fn(),
      reset: jest.fn(),
      getDeletedAttachments: jest.fn(() => []),
    }))
  })

  beforeEach(() => {
    document.body.innerHTML = '<div id="creatives"></div><div id="center-frame"></div>'
    saveMock.mockReset()
    buildEditorDom(document.getElementById('center-frame'))
    initializeCreativeRowEditor()
    document.getElementById('metadata-popup').style.display = 'none'
  })

  async function startFirstRowWithContent() {
    const emptyState = renderEmptyState()
    emptyState.querySelector('.new-root-creative-btn').click()
    await flush()

    // Typing marks the buffer dirty so hideCurrent() actually attempts a save.
    const description = document.getElementById('inline-creative-description')
    description.value = '<p>first creative</p>'
    const textarea = document.getElementById('markdown-editor-textarea')
    textarea.value = 'first creative'
    textarea.dispatchEvent(new Event('input'))

    return emptyState
  }

  test('hides the empty state while the first inline row is being created', async () => {
    const emptyState = await startFirstRowWithContent()

    expect(emptyState.style.display).toBe('none')
    expect(document.querySelectorAll('#creatives creative-tree-row')).toHaveLength(1)
  })

  test('restores the empty state when the first save rejects', async () => {
    saveMock.mockImplementation(() => Promise.reject(new Error('network down')))
    const emptyState = await startFirstRowWithContent()

    document.getElementById('inline-close').click()
    await flush()

    expect(saveMock).toHaveBeenCalledTimes(1)
    // Without recovery both the card and the unsaved row are invisible, leaving
    // the tree blank with no way back.
    expect(emptyState.style.display).toBe('')
    expect(document.querySelectorAll('#creatives creative-tree-row')).toHaveLength(0)
  })

  test('still restores the empty state when the blank first row is cancelled', async () => {
    const emptyState = renderEmptyState()
    emptyState.querySelector('.new-root-creative-btn').click()
    await flush()

    document.getElementById('inline-close').click()
    await flush()

    expect(saveMock).not.toHaveBeenCalled()
    expect(emptyState.style.display).toBe('')
    expect(document.querySelectorAll('#creatives creative-tree-row')).toHaveLength(0)
  })

  test('brings an existing row back into view when its save rejects', async () => {
    saveMock.mockImplementation(() => Promise.reject(new Error('network down')))

    const rowComponent = document.createElement('creative-tree-row')
    rowComponent.dataset.descriptionRawHtml = '<p>existing</p>'
    rowComponent.dataset.progressValue = '0'
    // The stub only renders its .creative-tree child once connected.
    document.getElementById('creatives').appendChild(rowComponent)
    const tree = rowComponent.querySelector('.creative-tree')
    tree.id = 'creative-42'
    tree.dataset.id = '42'
    const row = document.createElement('div')
    row.className = 'creative-row'
    tree.appendChild(row)

    document.dispatchEvent(new CustomEvent('creative-edit-click', { detail: { treeElement: tree } }))
    await flush()
    expect(row.style.display).toBe('none')

    const textarea = document.getElementById('markdown-editor-textarea')
    textarea.value = 'edited'
    textarea.dispatchEvent(new Event('input'))

    document.getElementById('inline-close').click()
    await flush()

    expect(saveMock).toHaveBeenCalledTimes(1)
    expect(document.getElementById('creative-42')).not.toBeNull()
    expect(row.style.display).toBe('')
  })
})
