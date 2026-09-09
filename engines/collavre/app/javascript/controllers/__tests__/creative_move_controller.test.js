/** @jest-environment jsdom */
import { jest } from '@jest/globals'
import { Application } from '@hotwired/stimulus'

const alertDialog = jest.fn(() => Promise.resolve())
jest.unstable_mockModule('../../lib/utils/dialog', () => ({ alertDialog }))
const executeMoveCommand = jest.fn()
const invalidateCreativeTree = jest.fn()
jest.unstable_mockModule('../../creatives/drag_drop/move_command', () => ({ executeMoveCommand }))
jest.unstable_mockModule('../../lib/creative_tree_invalidation', () => ({ invalidateCreativeTree }))
const { default: CreativeMoveController } = await import('../creative_move_controller')

const flush = async () => { await Promise.resolve(); await Promise.resolve() }
let app, controller, picker, dialog
beforeEach(async () => {
  jest.clearAllMocks()
  document.body.innerHTML = `
    <button data-creative-move-id="1" data-creative-move-writable="true">Move</button>
    <creative-tree-row creative-id="1" can-write><input class="select-creative-checkbox" type="checkbox" value="1" checked></creative-tree-row>
    <creative-tree-row creative-id="2" can-write><input class="select-creative-checkbox" type="checkbox" value="2" checked></creative-tree-row>
    <div id="link-creative-modal"></div>
    <div data-controller="creative-move" data-creative-move-messages-value='{"empty":"No selectable creatives","archived":"Deselect archived creatives","choose":"Choose","invalid":"Invalid","moving":"Moving","complete":"Done","partial":"Partial","failed":"Failed","cancelled":"Cancelled"}'>
      <dialog data-creative-move-target="dialog"><button data-creative-move-target="destination"></button>
      <select data-creative-move-target="direction"><option value="child">Child</option><option value="up">Before</option><option value="down">After</option></select>
      <select data-creative-move-target="mode"><option value="move">Move</option><option value="link">Link</option></select>
      <button data-creative-move-target="confirm"></button><p data-creative-move-target="status"></p></dialog>
      <span data-creative-move-target="announcement"></span>
    </div>`
  dialog = document.querySelector('dialog')
  dialog.showModal = jest.fn(() => { dialog.open = true })
  dialog.close = jest.fn(() => { dialog.open = false })
  app = Application.start()
  app.register('creative-move', CreativeMoveController)
  await flush()
  controller = app.getControllerForElementAndIdentifier(document.querySelector('[data-controller]'), 'creative-move')
  picker = { open: jest.fn() }
  jest.spyOn(app, 'getControllerForElementAndIdentifier').mockReturnValue(picker)
  document.querySelector('[data-creative-move-id]').click()
})
afterEach(() => { controller.disconnect(); app.stop(); document.body.innerHTML = '' })
const destination = (id = 99) => {
  controller.chooseDestination()
  const [, select, close, options] = picker.open.mock.calls.at(-1)
  expect(options).toEqual({ allowCreate: false, selectOrigin: false })
  expect(dialog.open).toBe(false)
  select({ id, label: 'Off-screen creative' })
  close()
}
const submit = () => controller.submit({ preventDefault: jest.fn() })

test('offers link mode for a readable source and never submits a forbidden move', async () => {
  controller.cancel()
  const button = document.querySelector('[data-creative-move-id]')
  document.querySelector('creative-tree-row').removeAttribute('can-write')
  button.click()
  expect(dialog.open).toBe(true)
  expect(controller.modeTarget.value).toBe('link')
  expect(controller.modeTarget.querySelector('[value="move"]').disabled).toBe(true)
  destination()
  controller.modeTarget.value = 'move'
  await submit()
  expect(executeMoveCommand).not.toHaveBeenCalled()
  controller.modeTarget.value = 'link'
  executeMoveCommand.mockResolvedValue({ status: 'success', ok: true, succeededIds: ['1', '2'], failedIds: [] })
  await submit()
  expect(executeMoveCommand).toHaveBeenCalledWith(expect.objectContaining({ mode: 'link', ids: ['1', '2'] }))
});

test.each([false, true])('selected read-only-origin shells stay link-only with a writable header (mixed: %s)', async mixed => {
  controller.cancel()
  // TreeBuilder supplies this capability after resolving the shell's origin.
  document.querySelector('creative-tree-row[creative-id="1"]').removeAttribute('can-write')
  document.querySelector('.select-creative-checkbox[value="2"]').checked = mixed
  document.querySelector('[data-creative-move-id]').click()
  const ids = mixed ? ['1', '2'] : ['1']
  expect(controller.ids).toEqual(ids)
  expect(controller.modeTarget.value).toBe('link')
  expect(controller.modeTarget.querySelector('[value="move"]').disabled).toBe(true)
  destination()
  controller.modeTarget.value = 'move'
  await submit()
  expect(executeMoveCommand).not.toHaveBeenCalled()
  controller.modeTarget.value = 'link'
  executeMoveCommand.mockResolvedValue({ status: 'success', ok: true, succeededIds: ids, failedIds: [] })
  await submit()
  expect(executeMoveCommand).toHaveBeenCalledWith({ ids, targetId: '99', direction: 'child', mode: 'link' })
})

test('keeps move disabled after a readable bundle link partially fails and retries only missing links', async () => {
  controller.cancel()
  const button = document.querySelector('[data-creative-move-id]')
  document.querySelector('creative-tree-row').removeAttribute('can-write')
  button.click()
  destination()
  executeMoveCommand.mockResolvedValueOnce({ status: 'partial', ok: false, succeededIds: ['1'], failedIds: ['2'] })
  await submit()
  expect(controller.ids).toEqual(['2'])
  expect(controller.modeTarget.disabled).toBe(false)
  expect(controller.modeTarget.querySelector('[value="move"]').disabled).toBe(true)
  expect(controller.modeTarget.value).toBe('link')
  executeMoveCommand.mockResolvedValueOnce({ status: 'success', ok: true, succeededIds: ['2'], failedIds: [] })
  await submit()
  expect(executeMoveCommand).toHaveBeenLastCalledWith({ ids: ['2'], targetId: '99', direction: 'child', mode: 'link' })
})

test('a mixed-permission selection defaults to links and a later writable selection can move', () => {
  controller.cancel()
  document.querySelector('creative-tree-row[creative-id="2"]').removeAttribute('can-write')
  document.querySelector('[data-creative-move-id="1"]').click()
  expect(controller.modeTarget.value).toBe('link')
  controller.cancel()
  document.querySelector('.select-creative-checkbox[value="2"]').checked = false
  document.querySelector('[data-creative-move-id="1"]').click()
  expect(controller.modeTarget.value).toBe('move')
  expect(controller.modeTarget.querySelector('[value="move"]').disabled).toBe(false)
});

test('opens a native modal from a button and uses the shared picker for off-screen destinations', () => {
  expect(dialog.open).toBe(true)
  expect(controller.ids).toEqual(['1', '2'])
  expect(document.activeElement).toBe(controller.destinationTarget)
  expect(controller.confirmTarget.disabled).toBe(true)
  destination()
  expect(dialog.open).toBe(true)
  expect(controller.targetId).toBe('99')
  expect(controller.destinationTarget.textContent).toBe('Off-screen creative')
  expect(controller.confirmTarget.disabled).toBe(false)
})

test.each(['child', 'up', 'down'])('executes %s through the command and refreshes both trees', async direction => {
  destination()
  controller.directionTarget.value = direction
  controller.modeTarget.value = 'link'
  executeMoveCommand.mockResolvedValue({ status: 'success', ok: true, succeededIds: ['1', '2'], failedIds: [] })
  await submit()
  expect(executeMoveCommand).toHaveBeenCalledWith({ ids: ['1', '2'], targetId: '99', direction, mode: 'link' })
  expect(invalidateCreativeTree).toHaveBeenCalledWith({ direction, targetCreativeId: '99' })
  expect(dialog.open).toBe(false)
  expect(controller.announcementTarget.textContent).toBe('Done')
  expect(document.activeElement).toBe(document.querySelector('[data-creative-move-id]'))
})

test('rejects a selected creative as destination without submitting', async () => {
  destination(2)
  expect(controller.statusTarget.textContent).toBe('Invalid')
  expect(controller.confirmTarget.disabled).toBe(true)
  await submit()
  expect(executeMoveCommand).not.toHaveBeenCalled()
})

test('retries only failed items after a partial link result', async () => {
  destination()
  executeMoveCommand.mockResolvedValueOnce({ status: 'partial', ok: false, succeededIds: ['1'], failedIds: ['2'] })
  await submit()
  expect(dialog.open).toBe(true)
  expect(controller.statusTarget.textContent).toBe('Partial')
  executeMoveCommand.mockResolvedValueOnce({ status: 'success', ok: true, succeededIds: ['2'], failedIds: [] })
  await submit()
  expect(executeMoveCommand.mock.calls[1][0].ids).toEqual(['2'])
})

test('blocks duplicate submissions and cancellation while pending, then allows retry on failure', async () => {
  destination()
  let resolve
  executeMoveCommand.mockReturnValueOnce(new Promise(done => { resolve = done }))
  const pending = submit()
  await submit()
  controller.cancel({ preventDefault: jest.fn() })
  expect(dialog.open).toBe(true)
  expect(executeMoveCommand).toHaveBeenCalledTimes(1)
  resolve({ status: 'failure', ok: false, succeededIds: [], failedIds: ['1', '2'] })
  await pending
  expect(invalidateCreativeTree).not.toHaveBeenCalled()
  expect(controller.statusTarget.textContent).toBe('Failed')
  expect(controller.confirmTarget.disabled).toBe(false)
})

test('handles unexpected rejection and unavailable picker', async () => {
  destination()
  executeMoveCommand.mockRejectedValueOnce(new Error('Network'))
  await submit()
  expect(controller.statusTarget.textContent).toBe('Failed')
  app.getControllerForElementAndIdentifier.mockReturnValue(null)
  controller.chooseDestination()
  expect(dialog.open).toBe(true)
})

test('Escape/cancel restores button focus without a mutation', () => {
  controller.cancel({ preventDefault: jest.fn() })
  expect(dialog.open).toBe(false)
  expect(controller.announcementTarget.textContent).toBe('Cancelled')
  expect(document.activeElement).toBe(document.querySelector('[data-creative-move-id]'))
  expect(executeMoveCommand).not.toHaveBeenCalled()
})

test('picker cancellation reopens the dialog without enabling confirmation', () => {
  controller.chooseDestination()
  picker.open.mock.calls[0][2]()
  expect(dialog.open).toBe(true)
  expect(controller.confirmTarget.disabled).toBe(true)
})

test('a header action prioritizes the selected rows and detached triggers recover to another button', () => {
  controller.cancel()
  const other = document.createElement('button')
  other.dataset.creativeMoveId = '3'
  document.body.prepend(other)
  other.click()
  expect(controller.ids).toEqual(['1', '2'])
  other.remove()
  controller.cancel()
  expect(document.activeElement).toBe(document.querySelector('[data-creative-move-id]'))
})

test('disconnect removes delegated click handling and prevents picker reopening', () => {
  controller.chooseDestination()
  controller.disconnect()
  const showCount = dialog.showModal.mock.calls.length
  picker.open.mock.calls[0][2]()
  document.querySelector('[data-creative-move-id]').click()
  expect(dialog.showModal).toHaveBeenCalledTimes(showCount)
})

test('restores focus after asynchronous tree replacement without stealing user focus', async () => {
  destination()
  executeMoveCommand.mockResolvedValue({ status: 'success', ok: true, succeededIds: ['1', '2'], failedIds: [] })
  await submit()
  document.body.append(document.createElement('div'))
  await flush()
  expect(document.activeElement).toBe(document.querySelector('[data-creative-move-id]'))
  const replacement = document.createElement('button')
  replacement.dataset.creativeMoveId = '99'
  document.querySelector('[data-creative-move-id]').replaceWith(replacement)
  await flush()
  expect(document.activeElement).toBe(replacement)

  replacement.click()
  destination(100)
  await submit()
  const input = document.createElement('input')
  document.body.append(input)
  input.focus()
  await flush()
  replacement.remove()
  await flush()
  expect(document.activeElement).toBe(input)
})

test('recovers focus onto the moved creative rather than the first row', async () => {
  const first = document.createElement('button')
  first.dataset.creativeMoveId = '7'
  document.body.prepend(first)
  destination()
  executeMoveCommand.mockResolvedValue({ status: 'success', ok: true, succeededIds: ['1', '2'], failedIds: [] })
  await submit()

  const replacement = document.createElement('button')
  replacement.dataset.creativeMoveId = '1'
  document.querySelector('[data-creative-move-id="1"]').replaceWith(replacement)
  await flush()

  expect(document.activeElement).toBe(replacement)
})

test('falls back to any button when the moved creative left both trees', async () => {
  destination()
  executeMoveCommand.mockResolvedValue({ status: 'success', ok: true, succeededIds: ['1', '2'], failedIds: [] })
  await submit()

  const survivor = document.createElement('button')
  survivor.dataset.creativeMoveId = '7'
  document.querySelector('[data-creative-move-id="1"]').replaceWith(survivor)
  await flush()

  expect(document.activeElement).toBe(survivor)
})

test('does not update disconnected dialog after a command completes', async () => {
  destination()
  let resolve
  executeMoveCommand.mockReturnValueOnce(new Promise(done => { resolve = done }))
  const pending = submit()
  controller.disconnect()
  resolve({ status: 'success', ok: true, succeededIds: ['1'], failedIds: [] })
  await pending
  expect(invalidateCreativeTree).toHaveBeenCalledTimes(1)
  expect(controller.announcementTarget.textContent).toBe('')
})

test('ignores clicks while picker is open and submissions without a destination', async () => {
  document.body.click()
  await submit()
  expect(executeMoveCommand).not.toHaveBeenCalled()
  controller.chooseDestination()
  document.querySelector('[data-creative-move-id]').click()
  expect(dialog.open).toBe(false)
})

test('silences a rejected request after disconnection', async () => {
  destination()
  let reject
  executeMoveCommand.mockReturnValueOnce(new Promise((_, fail) => { reject = fail }))
  const pending = submit()
  controller.disconnect()
  reject(new Error('Disconnected'))
  await pending
  expect(controller.statusTarget.textContent).toBe('Moving')
})

test('missing picker element fails without leaving the modal', () => {
  document.getElementById('link-creative-modal').remove()
  controller.chooseDestination()
  expect(controller.statusTarget.textContent).toBe('Failed')
  expect(dialog.open).toBe(true)
})


test('an authentication redirect is a failure, preserves selection, and never announces success', async () => {
  destination()
  executeMoveCommand.mockResolvedValueOnce({
    status: 'failure', ok: false, succeededIds: [], failedIds: ['1', '2'],
    failures: [{ id: '1', reason: 'authentication_required' }, { id: '2', reason: 'authentication_required' }]
  })
  await submit()
  expect(invalidateCreativeTree).not.toHaveBeenCalled()
  expect(dialog.open).toBe(true)
  expect(controller.statusTarget.textContent).toBe('Failed')
  expect(controller.announcementTarget.textContent).toBe('')
  expect(controller.ids).toEqual(['1', '2'])
  expect(controller.confirmTarget.disabled).toBe(false)
})


test('uses the current creative when nothing is selected, including its read-only capability', () => {
  controller.cancel()
  document.querySelectorAll('.select-creative-checkbox').forEach(el => { el.checked = false })
  const button = document.querySelector('[data-creative-move-id]')
  button.click()
  expect(controller.ids).toEqual(['1'])
  expect(controller.modeTarget.value).toBe('move')
  controller.cancel()
  button.dataset.creativeMoveWritable = 'false'
  button.click()
  expect(controller.modeTarget.value).toBe('link')
  expect(controller.modeTarget.querySelector('option[value="move"]').disabled).toBe(true)
})

test('root action starts selection instead of opening an empty move dialog', () => {
  controller.cancel()
  document.querySelectorAll('.select-creative-checkbox').forEach(el => { el.checked = false })
  const button = document.querySelector('[data-creative-move-id]')
  button.dataset.creativeMoveId = ''
  const select = document.createElement('button')
  select.id = 'select-creative-btn'
  const startSelection = jest.fn(() => select.setAttribute('aria-pressed', 'true'))
  select.addEventListener('click', startSelection)
  document.body.appendChild(select)
  button.click()
  expect(dialog.open).toBe(false)
  expect(startSelection).toHaveBeenCalledTimes(1)
  expect(document.activeElement).toBe(document.querySelector('.select-creative-checkbox'))
  button.click()
  expect(startSelection).toHaveBeenCalledTimes(1)
  document.querySelector('.select-creative-checkbox[value="2"]').checked = true
  button.click()
  expect(controller.ids).toEqual(['2'])
  expect(dialog.open).toBe(true)
})

test.each(['arrive', 'focus-away', 'disconnect'])('root selection waits for CSR rows: %s', async outcome => {
  controller.cancel()
  document.querySelectorAll('creative-tree-row').forEach(row => row.remove())
  const action = document.querySelector('[data-creative-move-id]')
  action.dataset.creativeMoveId = ''
  const wrapper = document.createElement('div')
  wrapper.dataset.controller = 'popup-menu'
  wrapper.innerHTML = '<button data-popup-menu-target="button">…</button><div hidden></div>'
  document.body.prepend(wrapper)
  wrapper.lastElementChild.appendChild(action)
  const select = document.createElement('button')
  select.id = 'select-creative-btn'
  wrapper.lastElementChild.appendChild(select)
  const startSelection = jest.fn(() => {
    select.setAttribute('aria-pressed', 'true')
    document.querySelectorAll('.select-creative-checkbox').forEach(el => { el.style.display = '' })
  })
  select.addEventListener('click', startSelection)
  action.click()
  expect(startSelection).not.toHaveBeenCalled()
  expect(document.activeElement).toBe(wrapper.firstElementChild)
  expect(dialog.open).toBe(false)
  let other
  if (outcome === 'focus-away') {
    other = document.createElement('button')
    document.body.appendChild(other)
    other.focus()
  }
  if (outcome === 'disconnect') controller.disconnect()
  document.body.insertAdjacentHTML('beforeend', '<input type="checkbox" class="select-creative-checkbox" value="7" style="display:none">')
  await flush()
  if (outcome === 'arrive') {
    const checkbox = document.querySelector('.select-creative-checkbox')
    expect(startSelection).toHaveBeenCalledTimes(1)
    expect(checkbox.style.display).toBe('')
    expect(document.activeElement).toBe(checkbox)
    checkbox.checked = true
    action.click()
    expect(controller.ids).toEqual(['7'])
    expect(dialog.open).toBe(true)
  } else {
    expect(startSelection).not.toHaveBeenCalled()
    if (other) expect(document.activeElement).toBe(other)
  }
})

test('returns focus to the visible overflow toggle on cancel and after replacement', async () => {
  controller.cancel()
  const action = document.querySelector('[data-creative-move-id]')
  const wrapper = document.createElement('div')
  wrapper.dataset.controller = 'popup-menu'
  wrapper.innerHTML = '<button data-popup-menu-target="button">…</button><div id="creative-overflow-menu"></div>'
  document.body.prepend(wrapper)
  wrapper.lastElementChild.appendChild(action)
  action.click()
  controller.cancel()
  expect(document.activeElement).toBe(wrapper.firstElementChild)
  action.click()
  destination()
  executeMoveCommand.mockResolvedValue({ ok: true, succeededIds: ['1', '2'], failedIds: [] })
  await submit()
  const replacement = wrapper.cloneNode(true)
  wrapper.replaceWith(replacement)
  await flush()
  expect(document.activeElement).toBe(replacement.firstElementChild)
})

test.each(['', 'true'])('rejects archived-only and mixed selections with archived="%s" for both modes', async archived => {
  controller.cancel()
  const rows = [...document.querySelectorAll('creative-tree-row')]
  rows[0].setAttribute('archived', archived)
  for (const mixed of [false, true]) {
    rows[1].querySelector('input').checked = mixed
    for (const mode of ['move', 'link']) {
      alertDialog.mockClear()
      controller.modeTarget.value = mode
      document.querySelector('[data-creative-move-id]').click()
      expect(dialog.open).toBe(false)
      expect(alertDialog).toHaveBeenCalledTimes(1)
      expect(alertDialog).toHaveBeenCalledWith('Deselect archived creatives')
      await flush()
      expect(document.activeElement).toBe(document.querySelector('[data-creative-move-id]'))
      expect(controller.ids).toEqual([])
      expect(controller.announcementTarget.textContent).toBe('Deselect archived creatives')
      await submit()
      expect(executeMoveCommand).not.toHaveBeenCalled()
    }
  }
  alertDialog.mockClear()
  rows[0].removeAttribute('archived')
  document.querySelector('[data-creative-move-id]').click()
  expect(dialog.open).toBe(true)
  expect(alertDialog).not.toHaveBeenCalled()
  expect(controller.ids).toEqual(['1', '2'])
})


test.each(['already-empty', 'finishes-empty', 'focus-away', 'disconnect'])(
  'root empty completion stops selection waiting: %s', async outcome => {
    controller.cancel()
    document.querySelectorAll('creative-tree-row').forEach(row => row.remove())
    const tree = document.createElement('div')
    tree.id = 'creatives'
    document.body.appendChild(tree)
    if (outcome === 'already-empty') tree.dataset.loaded = 'true'
    const action = document.querySelector('[data-creative-move-id]')
    action.dataset.creativeMoveId = ''
    const wrapper = document.createElement('div')
    wrapper.dataset.controller = 'popup-menu'
    wrapper.innerHTML = '<button data-popup-menu-target="button">…</button><div hidden></div>'
    document.body.prepend(wrapper)
    wrapper.lastElementChild.appendChild(action)
    const select = document.createElement('button')
    select.id = 'select-creative-btn'
    const startSelection = jest.fn()
    select.addEventListener('click', startSelection)
    wrapper.lastElementChild.appendChild(select)
    action.click()
    let other
    if (outcome === 'focus-away') {
      other = document.createElement('button')
      document.body.appendChild(other)
      other.focus()
    }
    if (outcome === 'disconnect') controller.disconnect()
    tree.dataset.loaded = 'true'
    await flush()
    const abandoned = ['focus-away', 'disconnect'].includes(outcome)
    expect(alertDialog).toHaveBeenCalledTimes(abandoned ? 0 : 1)
    if (!abandoned) {
      expect(alertDialog).toHaveBeenCalledWith('No selectable creatives')
      expect(controller.announcementTarget.textContent).toBe('No selectable creatives')
      expect(document.activeElement).toBe(wrapper.firstElementChild)
    }
    expect(dialog.open).toBe(false)
    expect(startSelection).not.toHaveBeenCalled()
    // A later tree change must not revive the completed/abandoned request.
    tree.innerHTML = '<input type="checkbox" class="select-creative-checkbox" value="7">'
    await flush()
    expect(startSelection).not.toHaveBeenCalled()
    expect(alertDialog).toHaveBeenCalledTimes(abandoned ? 0 : 1)
    expect(executeMoveCommand).not.toHaveBeenCalled()
    if (other) expect(document.activeElement).toBe(other)
  }
)


test.each([
  ['empty', false], ['empty', true], ['archived', false], ['archived', true]
])('%s feedback restores focus after dismissal unless disconnected: %s', async (kind, disconnected) => {
  controller.cancel()
  document.querySelectorAll('creative-tree-row').forEach(row => row.remove())
  document.body.insertAdjacentHTML('beforeend', '<div id="creatives" data-loaded="true"></div>')
  const action = document.querySelector('[data-creative-move-id]')
  action.dataset.creativeMoveId = ''
  if (kind === 'archived') {
    document.body.insertAdjacentHTML('beforeend', '<creative-tree-row archived><input type="checkbox" class="select-creative-checkbox" checked value="1"></creative-tree-row>')
  }
  let dismiss
  alertDialog.mockImplementationOnce(() => new Promise(resolve => { dismiss = resolve }))
  const restore = jest.spyOn(controller, 'restoreFocus')
  action.click()
  expect(restore).not.toHaveBeenCalled()
  if (disconnected) controller.disconnect()
  dismiss()
  await flush()
  expect(restore).toHaveBeenCalledTimes(disconnected ? 0 : 1)
})

// CSR emits unrelated mutations long before the rows land. The observer must
// keep waiting through them instead of falling through to either outcome.
test('unrelated mutations keep the root request waiting until rows arrive', async () => {
  controller.cancel()
  document.querySelectorAll('creative-tree-row').forEach(row => row.remove())
  const tree = document.createElement('div')
  tree.id = 'creatives'
  document.body.appendChild(tree)
  const action = document.querySelector('[data-creative-move-id]')
  action.dataset.creativeMoveId = ''
  const select = document.createElement('button')
  select.id = 'select-creative-btn'
  document.body.appendChild(select)
  action.click()
  expect(document.activeElement).toBe(action)
  tree.appendChild(document.createElement('span'))
  await flush()
  expect(select.getAttribute('aria-pressed')).toBe(null)
  expect(alertDialog).not.toHaveBeenCalled()
  tree.innerHTML = '<input type="checkbox" class="select-creative-checkbox" value="7">'
  await flush()
  expect(document.activeElement).toBe(tree.firstElementChild)
  expect(alertDialog).not.toHaveBeenCalled()
})

// The error text lives on a Stimulus value the tree partial always renders, but
// a cached or partially rendered container may not carry it yet.
test('a load failure without the tree error text falls back to the generic failure', async () => {
  controller.cancel()
  document.querySelectorAll('creative-tree-row').forEach(row => row.remove())
  const tree = document.createElement('div')
  tree.id = 'creatives'
  tree.dataset.loadState = 'error'
  tree.dataset.loaded = 'true'
  document.body.appendChild(tree)
  const action = document.querySelector('[data-creative-move-id]')
  action.dataset.creativeMoveId = ''
  action.click()
  await flush()
  expect(alertDialog).toHaveBeenCalledWith('Failed')
  expect(controller.announcementTarget.textContent).toBe('Failed')
  expect(dialog.open).toBe(false)
  expect(document.activeElement).toBe(action)
})

test.each([false, true])('root load failure preserves error feedback, already completed: %s', async completed => {
  controller.cancel()
  document.querySelectorAll('creative-tree-row').forEach(row => row.remove())
  const tree = document.createElement('div')
  tree.id = 'creatives'
  tree.setAttribute('data-creatives--tree-error-text-value', 'Could not load the creative tree.')
  document.body.appendChild(tree)
  const fail = () => {
    tree.dataset.loadState = 'error'
    tree.dataset.loaded = 'true'
    tree.innerHTML = '<p class="creative-tree-error">Could not load the creative tree.</p>'
  }
  if (completed) fail()
  const action = document.querySelector('[data-creative-move-id]')
  action.dataset.creativeMoveId = ''
  action.click()
  if (!completed) fail()
  await flush()
  expect(alertDialog).toHaveBeenCalledTimes(1)
  expect(alertDialog).toHaveBeenCalledWith('Could not load the creative tree.')
  expect(controller.announcementTarget.textContent).toBe('Could not load the creative tree.')
  expect(tree.querySelector('.creative-tree-error')).not.toBeNull()
  expect(dialog.open).toBe(false)
  expect(document.activeElement).toBe(action)
  tree.innerHTML = '<input type="checkbox" class="select-creative-checkbox" value="7">'
  await flush()
  expect(document.activeElement).toBe(action)
  expect(alertDialog).toHaveBeenCalledTimes(1)
  expect(executeMoveCommand).not.toHaveBeenCalled()
})


test.each(['move', 'link'])('archived-parent selection launcher submits only the active child in %s mode', async mode => {
  controller.cancel()
  const action = document.querySelector('[data-creative-move-id]')
  // The helper omits the archived current parent's ID, retaining selection.
  action.dataset.creativeMoveId = ''
  document.querySelectorAll('.select-creative-checkbox').forEach(el => { el.checked = false })
  const select = document.createElement('button')
  select.id = 'select-creative-btn'
  const startSelection = jest.fn(() => select.setAttribute('aria-pressed', 'true'))
  select.addEventListener('click', startSelection)
  document.body.appendChild(select)
  action.click()
  expect(dialog.open).toBe(false)
  expect(controller.ids).toEqual([])
  expect(startSelection).toHaveBeenCalledTimes(1)
  document.querySelector('.select-creative-checkbox[value="2"]').checked = true
  action.click()
  expect(dialog.open).toBe(true)
  expect(controller.modeTarget.value).toBe('move')
  destination()
  controller.modeTarget.value = mode
  executeMoveCommand.mockResolvedValue({ ok: true, succeededIds: ['2'], failedIds: [] })
  await submit()
  expect(executeMoveCommand).toHaveBeenCalledWith({ ids: ['2'], targetId: '99', direction: 'child', mode })
})
