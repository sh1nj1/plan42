/**
 * @jest-environment jsdom
 */
import { jest } from '@jest/globals'

// The real inline editor is a JSX module (untransformed in Jest) and the
// delegated click handler is exercised by its own test file — both are
// mocked here so this file can observe the session lifecycle itself.
const createInlineEditorMock = jest.fn()
const createDelegatedClickHandlerMock = jest.fn()

jest.unstable_mockModule('../lexical_inline_editor', () => ({
  createInlineEditor: createInlineEditorMock,
}))
jest.unstable_mockModule('../creative_row_editor_delegated_clicks', () => ({
  createDelegatedClickHandler: createDelegatedClickHandlerMock,
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

function swapCenterContent() {
  const container = document.getElementById('center-frame')
  container.innerHTML = ''
  return buildEditorDom(container)
}

describe('creative row editor session lifecycle', () => {
  beforeAll(() => {
    document.body.innerHTML = '<div id="creatives"></div><div id="center-frame"></div>'
    createInlineEditorMock.mockImplementation(() => ({
      destroy: jest.fn(),
      load: jest.fn(),
      focus: jest.fn(),
      getDeletedAttachments: jest.fn(() => []),
    }))
    createDelegatedClickHandlerMock.mockImplementation(() => jest.fn())
  })

  test('builds a session for the mounted template on first initialization', () => {
    const template = swapCenterContent()

    initializeCreativeRowEditor()

    expect(createDelegatedClickHandlerMock).toHaveBeenCalledTimes(1)
    expect(createDelegatedClickHandlerMock.mock.calls[0][0].template).toBe(template)
  })

  test('stays idempotent while the same template remains mounted', () => {
    const calls = createDelegatedClickHandlerMock.mock.calls.length

    initializeCreativeRowEditor()
    document.dispatchEvent(new Event('turbo:load'))

    expect(createDelegatedClickHandlerMock).toHaveBeenCalledTimes(calls)
  })

  test('rebuilds the session against the new template after a center frame swap', () => {
    const previousEditor = createInlineEditorMock.mock.results.at(-1).value
    const newTemplate = swapCenterContent()

    // Non-promoted frame navigations fire no turbo:load; the Stimulus wrapper
    // reconnecting inside the swapped frame content is the only signal.
    initializeCreativeRowEditor()

    const session = createDelegatedClickHandlerMock.mock.calls.at(-1)[0]
    expect(session.template).toBe(newTemplate)
    expect(previousEditor.destroy).toHaveBeenCalledTimes(1)
  })

  test('rebuilds the session from turbo:load after a full page navigation', () => {
    const calls = createDelegatedClickHandlerMock.mock.calls.length
    const newTemplate = swapCenterContent()

    document.dispatchEvent(new Event('turbo:load'))

    expect(createDelegatedClickHandlerMock).toHaveBeenCalledTimes(calls + 1)
    expect(createDelegatedClickHandlerMock.mock.calls.at(-1)[0].template).toBe(newTemplate)
  })

  test('tears down the session when no template is mounted', () => {
    const previousEditor = createInlineEditorMock.mock.results.at(-1).value
    document.getElementById('center-frame').innerHTML = ''

    document.dispatchEvent(new Event('turbo:load'))

    expect(previousEditor.destroy).toHaveBeenCalledTimes(1)
    // A later mount recovers with a fresh session.
    const template = swapCenterContent()
    initializeCreativeRowEditor()
    expect(createDelegatedClickHandlerMock.mock.calls.at(-1)[0].template).toBe(template)
  })

  test('stops the orphaned editing ping when a frame swap discards a session with the editor open', () => {
    jest.useFakeTimers()
    const stopSpy = jest.fn()
    const startSpy = jest.fn()
    document.addEventListener('creative-editing:stop', stopSpy)
    document.addEventListener('creative-editing:start', startSpy)

    try {
      // Fresh session against a mounted template, same as a real workspace frame load.
      swapCenterContent()
      initializeCreativeRowEditor()
      // The cached-data fast path in loadCreative() bypasses the network only when
      // the popup is hidden; otherwise applyCreativeData() would fetch metadata.
      document.getElementById('metadata-popup').style.display = 'none'

      // A tree row with inline dataset (id/description/progress) so opening it
      // takes the synchronous cached-data path instead of an API call.
      const treeRow = document.createElement('creative-tree-row')
      treeRow.dataset.descriptionRawHtml = 'hello'
      treeRow.dataset.progressValue = '0'
      const tree = document.createElement('div')
      tree.className = 'creative-tree'
      tree.id = 'creative-42'
      tree.dataset.id = '42'
      treeRow.appendChild(tree)
      document.getElementById('center-frame').appendChild(treeRow)

      document.dispatchEvent(new CustomEvent('creative-edit-click', { detail: { treeElement: tree } }))

      expect(startSpy).toHaveBeenCalledTimes(1)
      expect(startSpy.mock.calls[0][0].detail.creativeId).toBe(42)

      // Workspace frame swap: center content is replaced wholesale and the
      // Stimulus wrapper reconnects, without the outgoing session ever calling
      // hideCurrent()/move() on itself.
      swapCenterContent()
      initializeCreativeRowEditor()

      expect(stopSpy).toHaveBeenCalledTimes(1)
      expect(stopSpy.mock.calls[0][0].detail.creativeId).toBe(42)

      startSpy.mockClear()
      jest.advanceTimersByTime(10000)
      expect(startSpy).not.toHaveBeenCalled()
    } finally {
      document.removeEventListener('creative-editing:stop', stopSpy)
      document.removeEventListener('creative-editing:start', startSpy)
      jest.useRealTimers()
    }
  })
})
