/**
 * @jest-environment jsdom
 */

import { jest } from '@jest/globals'

const alertDialog = jest.fn()
const confirmDialog = jest.fn(async () => true)
jest.unstable_mockModule('../../../lib/utils/dialog', () => ({ alertDialog, confirmDialog }))

const { default: ListController } = await import('../list_controller')

function buildController(ids) {
  document.head.innerHTML = '<meta name="csrf-token" content="token">'
  const element = document.createElement('div')
  ids.forEach((id) => {
    const item = document.createElement('div')
    item.id = `comment_${id}`
    element.appendChild(item)
  })
  document.body.appendChild(element)

  const controller = Object.create(ListController.prototype)
  Object.defineProperty(controller, 'element', { value: element })
  controller.creativeId = 7
  controller.selection = new Set(ids)
  controller.clearSelection = jest.fn()
  return controller
}

describe('list_controller batch delete', () => {
  let consoleError

  beforeEach(() => {
    consoleError = jest.spyOn(console, 'error').mockImplementation(() => {})
  })

  afterEach(() => {
    document.body.innerHTML = ''
    consoleError.mockRestore()
    jest.clearAllMocks()
    delete global.fetch
  })

  test('hides the selection before the request settles and removes it on success', async () => {
    let resolve
    global.fetch = jest.fn(() => new Promise((r) => { resolve = r }))
    const controller = buildController([ '1', '2' ])

    const pending = controller.deleteSelectedComments()
    await Promise.resolve()
    await Promise.resolve()

    expect(document.getElementById('comment_1').style.display).toBe('none')
    expect(document.getElementById('comment_2').style.display).toBe('none')
    expect(JSON.parse(global.fetch.mock.calls[0][1].body)).toEqual({ comment_ids: [ '1', '2' ] })

    resolve({ ok: true })
    await pending

    expect(document.getElementById('comment_1')).toBeNull()
    expect(document.getElementById('comment_2')).toBeNull()
    expect(controller.clearSelection).toHaveBeenCalled()
  })

  test('restores the rows when the server refuses', async () => {
    global.fetch = jest.fn(async () => ({ ok: false, json: async () => ({ error: 'nope' }) }))
    const controller = buildController([ '1' ])

    await controller.deleteSelectedComments()

    expect(document.getElementById('comment_1').style.display).toBe('')
    expect(alertDialog).toHaveBeenCalledWith('nope')
    expect(controller.clearSelection).not.toHaveBeenCalled()
  })

  test('restores the rows when the request fails', async () => {
    global.fetch = jest.fn(async () => { throw new Error('offline') })
    const controller = buildController([ '1' ])

    await controller.deleteSelectedComments()

    expect(document.getElementById('comment_1').style.display).toBe('')
    expect(alertDialog).toHaveBeenCalledWith('Failed to delete comments')
  })

  test('does nothing when the user cancels the confirmation', async () => {
    confirmDialog.mockResolvedValueOnce(false)
    global.fetch = jest.fn()
    const controller = buildController([ '1' ])

    await controller.deleteSelectedComments()

    expect(global.fetch).not.toHaveBeenCalled()
    expect(document.getElementById('comment_1').style.display).toBe('')
  })
})
