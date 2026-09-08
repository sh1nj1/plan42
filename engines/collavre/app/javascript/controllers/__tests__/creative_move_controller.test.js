/** @jest-environment jsdom */
import { jest } from '@jest/globals'
import { Application } from '@hotwired/stimulus'

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
    <button data-creative-move-id="1">Move</button>
    <input class="select-creative-checkbox" type="checkbox" value="1" checked>
    <input class="select-creative-checkbox" type="checkbox" value="2" checked>
    <div id="link-creative-modal"></div>
    <div data-controller="creative-move" data-creative-move-messages-value='{"choose":"Choose","invalid":"Invalid","moving":"Moving","complete":"Done","partial":"Partial","failed":"Failed","cancelled":"Cancelled"}'>
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

test('an unselected row acts only on itself and detached triggers recover to another button', () => {
  controller.cancel()
  const other = document.createElement('button')
  other.dataset.creativeMoveId = '3'
  document.body.prepend(other)
  other.click()
  expect(controller.ids).toEqual(['3'])
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
