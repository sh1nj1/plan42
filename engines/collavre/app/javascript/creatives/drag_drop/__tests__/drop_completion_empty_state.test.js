/**
 * @jest-environment jsdom
 */

// Dragging a row into another window removes it from *this* window's tree without
// any destroy happening, so no broadcast comes back to repair the DOM: the source
// window has to bring the empty-state placeholder back itself.
const { addGlobalListeners, removeGlobalListeners } = await import('../event_handlers')

const DROP_COMPLETED_EVENT = 'collavre:creative-drop-complete'
const WINDOW_ID_SESSION_KEY = 'collavre.dragWindowId'
const WINDOW_ID = 'window-under-test'

const EMPTY_HTML = '<div data-creatives-empty-state=""><p>No sub-creatives found.</p></div>'

function rowMarkup(id) {
  return `
    <creative-tree-row creative-id="${id}">
      <div class="creative-tree" id="creative-${id}" data-id="${id}" data-level="1">
        <div class="creative-row"></div>
      </div>
    </creative-tree-row>
  `
}

function mount(rowIds) {
  document.body.innerHTML = `
    <template id="creatives-empty-state-template">${EMPTY_HTML}</template>
    <div id="creatives">${rowIds.map(rowMarkup).join('')}</div>
  `
}

function container() {
  return document.getElementById('creatives')
}

function placeholder() {
  return container().querySelector('[data-creatives-empty-state]')
}

// No `direction` / `targetTreeId`: the source window could not resolve a local
// target, which is the branch that simply drops the row from this tree.
function dispatchDropCompleted(id) {
  window.dispatchEvent(new CustomEvent(DROP_COMPLETED_EVENT, {
    detail: {
      creativeId: id,
      treeId: `creative-${id}`,
      sourceWindowId: WINDOW_ID,
      context: 'source',
    },
  }))
}

beforeEach(() => {
  window.sessionStorage.setItem(WINDOW_ID_SESSION_KEY, WINDOW_ID)
  addGlobalListeners()
})

afterEach(() => {
  removeGlobalListeners()
  window.sessionStorage.clear()
  document.body.innerHTML = ''
})

test('dropping the last row into another window restores the placeholder', () => {
  mount(['7'])

  dispatchDropCompleted('7')

  expect(container().querySelector('creative-tree-row')).toBeNull()
  expect(placeholder()).not.toBeNull()
  expect(placeholder().hidden).toBe(false)
})

test('dropping one of several rows leaves the placeholder off the page', () => {
  mount(['7', '8'])

  dispatchDropCompleted('7')

  expect(container().querySelectorAll('creative-tree-row')).toHaveLength(1)
  expect(placeholder()).toBeNull()
})

test('a drop signalled for another window is ignored', () => {
  mount(['7'])

  window.dispatchEvent(new CustomEvent(DROP_COMPLETED_EVENT, {
    detail: {
      creativeId: '7',
      treeId: 'creative-7',
      sourceWindowId: 'some-other-window',
      context: 'source',
    },
  }))

  expect(container().querySelectorAll('creative-tree-row')).toHaveLength(1)
  expect(placeholder()).toBeNull()
})
