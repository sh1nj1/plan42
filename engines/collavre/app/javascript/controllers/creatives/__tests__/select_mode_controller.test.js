/**
 * @jest-environment jsdom
 */
import { jest } from '@jest/globals'

// Batch delete is DOM-repaired entirely client-side: the destroy broadcast
// excludes the initiating user, so nothing comes back to fix this window.
const csrfFetch = jest.fn(() => Promise.resolve({ ok: true }))
const confirmDialog = jest.fn(() => Promise.resolve(true))

jest.unstable_mockModule('../../../lib/api/csrf_fetch', () => ({
  default: csrfFetch,
  updateCsrfTokenFromResponse: jest.fn(),
  refreshCsrfToken: jest.fn(),
}))
jest.unstable_mockModule('../../../lib/utils/confirm_dialog', () => ({
  default: confirmDialog,
  confirmDialog,
}))

const { Application } = await import('@hotwired/stimulus')
const SelectModeController = (await import('../select_mode_controller')).default

const EMPTY_HTML = '<div data-creatives-empty-state=""><p>No sub-creatives found.</p></div>'

const flush = () => new Promise((resolve) => setTimeout(resolve, 0))

function rowMarkup(id) {
  return `
    <creative-tree-row creative-id="${id}">
      <div class="creative-tree" id="creative-${id}" data-id="${id}" data-level="1">
        <div class="creative-row" data-creatives--select-mode-target="row">
          <input type="checkbox" class="select-creative-checkbox" value="${id}"
                 data-creatives--select-mode-target="checkbox" />
        </div>
      </div>
    </creative-tree-row>
  `
}

// Post-client-render state: tree_controller wiped #creatives and rendered the rows
// into it, so the placeholder only survives in the out-of-container template. Rows
// are injected after the controller connects, as they are in the real app — the
// server always ships #creatives empty and the tree fetch fills it in.
async function mount(rowIds) {
  document.body.innerHTML = `
    <template id="creatives-empty-state-template">${EMPTY_HTML}</template>
    <div data-controller="creatives--select-mode">
      <button id="delete-selection-btn" data-confirm="Are you sure?"
              data-creatives--select-mode-target="deleteButton"></button>
      <div id="creatives"></div>
    </div>
  `

  const application = Application.start()
  application.register('creatives--select-mode', SelectModeController)
  await flush()

  container().innerHTML = rowIds.map(rowMarkup).join('')
  await flush()
  return application
}

function controllerFor(application) {
  return application.getControllerForElementAndIdentifier(
    document.querySelector('[data-controller="creatives--select-mode"]'),
    'creatives--select-mode'
  )
}

function container() {
  return document.getElementById('creatives')
}

function placeholder() {
  return container().querySelector('[data-creatives-empty-state]')
}

async function deleteSelected(application, ids) {
  ids.forEach((id) => {
    container().querySelector(`.select-creative-checkbox[value="${id}"]`).checked = true
  })
  await controllerFor(application).deleteSelected(new Event('click'))
  await flush()
}

let application

afterEach(() => {
  application?.stop()
  application = undefined
  jest.clearAllMocks()
  document.body.innerHTML = ''
})

test('deleting every selected row restores the empty-state placeholder', async () => {
  application = await mount(['7', '8'])

  await deleteSelected(application, ['7', '8'])

  expect(csrfFetch).toHaveBeenCalledTimes(2)
  expect(csrfFetch.mock.calls.map((call) => call[0])).toEqual([
    '/creatives/7?delete_with_children=false',
    '/creatives/8?delete_with_children=false',
  ])
  expect(placeholder()).not.toBeNull()
  expect(placeholder().hidden).toBe(false)
  expect(placeholder().textContent).toContain('No sub-creatives found.')
})

test('deleting a row takes its <creative-tree-row> wrapper with it', async () => {
  application = await mount(['7', '8'])

  await deleteSelected(application, ['7'])

  // An emptied-but-present wrapper would read as "tree still populated" and
  // suppress the placeholder forever.
  expect(container().querySelectorAll('creative-tree-row')).toHaveLength(1)
  expect(container().querySelector('creative-tree-row').getAttribute('creative-id')).toBe('8')
})

test('the placeholder stays away while rows remain', async () => {
  application = await mount(['7', '8'])

  await deleteSelected(application, ['7'])

  expect(placeholder()).toBeNull()
})

test('declining the confirmation deletes nothing', async () => {
  confirmDialog.mockResolvedValueOnce(false)
  application = await mount(['7'])

  await deleteSelected(application, ['7'])

  expect(csrfFetch).not.toHaveBeenCalled()
  expect(container().querySelectorAll('creative-tree-row')).toHaveLength(1)
  expect(placeholder()).toBeNull()
})
