/**
 * @jest-environment jsdom
 */
import { jest } from '@jest/globals'
import {
  trackCreate, pendingCreate, cannotEdit, postNewCreative, deferRowAnchor, takeDeferredAnchor,
  createEditTickets, trackNewRowSave, holdRenderForCreates, forgetFailedChain,
} from '../background_creative_create'

describe('background creative create bookkeeping', () => {
  test('tracks a create only while it is in flight', async () => {
    const tree = {}
    let resolve
    const promise = trackCreate(tree, new Promise((r) => { resolve = r }))

    expect(pendingCreate(tree)).toBe(promise)
    resolve({ afterId: '1', beforeId: '' })
    await promise
    await Promise.resolve()

    expect(pendingCreate(tree)).toBeUndefined()
  })

  test('defers a promised anchor and hands it out once', async () => {
    const tree = {}
    const input = { value: 'stale' }
    deferRowAnchor(tree, Promise.resolve({ afterId: '1', beforeId: '' }), input)

    expect(input.value).toBe('')
    await expect(takeDeferredAnchor(tree)).resolves.toEqual({ afterId: '1', beforeId: '' })
    expect(takeDeferredAnchor(tree)).toBeUndefined()
  })

  test('an edit request on a missing row is dropped, one with nothing in flight goes ahead', () => {
    const tickets = createEditTickets()
    expect(tickets.waitToEdit(null)).toBe(true)
    expect(tickets.waitToEdit({ dataset: { id: '1' } })).toBeFalsy()
  })

  test('writes a plain after_id straight through and drops any older deferral', () => {
    const tree = {}
    const input = { value: '' }
    deferRowAnchor(tree, Promise.resolve({}), input)

    deferRowAnchor(tree, '42', input)
    expect(input.value).toBe('42')
    expect(takeDeferredAnchor(tree)).toBeUndefined()

    deferRowAnchor(tree, '', input)
    expect(input.value).toBe('')
  })

  test('has nothing deferred for a missing tree', () => {
    expect(takeDeferredAnchor(null)).toBeUndefined()
  })

  test('cannot edit a missing row, can edit one with nothing in flight', async () => {
    expect(await cannotEdit(null)).toBe(true)
    expect(await cannotEdit({ dataset: { id: '1' } })).toBe(false)
  })

  test('treats a successful response without an id as a failed create', async () => {
    const tree = { dataset: {} }
    const failed = jest.fn()
    const fallback = { afterId: '3', beforeId: '' }
    const result = await postNewCreative(tree, { action: '/creatives', body: new FormData() }, fallback, {
      save: () => Promise.resolve({ ok: true, status: 200, text: () => Promise.resolve('') }),
      created: jest.fn(),
      failed,
    })

    expect(result).toEqual({ afterId: '3', beforeId: '', failedTrees: [tree] })
    expect(failed).toHaveBeenCalled()
    expect(tree.dataset.saveState).toBe('error')
  })

  describe('a render held for a create and a new row save', () => {
    function treeIn(frame) {
      const tree = document.createElement('div')
      tree.className = 'creative-tree'
      frame.appendChild(tree)
      return tree
    }

    test.each([
      ['goes ahead once the failed row has been retried successfully', true, 1],
      ['is dropped while the row whose save failed is still unsaved', false, 0],
    ])('%s', async (_name, retried, resumes) => {
      document.body.innerHTML = '<div id="frame"></div>'
      const frame = document.getElementById('frame')
      const creating = treeIn(frame)
      const saving = treeIn(frame)
      let finishCreate
      trackCreate(creating, new Promise((r) => { finishCreate = r }))
      trackNewRowSave(saving, Promise.resolve({ ok: false }))
      const event = { target: frame, detail: { resume: jest.fn() }, preventDefault: jest.fn() }
      const openRow = { keptUnsaved: () => false, flush: () => undefined, keep: jest.fn(), release: jest.fn() }

      holdRenderForCreates(event, jest.fn(), openRow, jest.fn())
      await new Promise((r) => setTimeout(r, 0))
      if (retried) {
        saving.dataset.id = '78'
        forgetFailedChain(saving)
      }
      finishCreate({ afterId: '77', beforeId: '' })
      await new Promise((r) => setTimeout(r, 0))

      expect(event.preventDefault).toHaveBeenCalled()
      expect(event.detail.resume).toHaveBeenCalledTimes(resumes)
      expect(openRow.keep).toHaveBeenCalledTimes(1 - resumes)
      expect(openRow.release).toHaveBeenCalledTimes(resumes)
    })
  })
})
