/**
 * @jest-environment jsdom
 */
import { jest } from '@jest/globals'
import {
  trackCreate, pendingCreate, cannotEdit, postNewCreative, deferRowAnchor, takeDeferredAnchor,
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

  test('defers a promised anchor and hands it out once', () => {
    const tree = {}
    const input = { value: 'stale' }
    const anchor = Promise.resolve({ afterId: '1', beforeId: '' })

    deferRowAnchor(tree, anchor, input)

    expect(input.value).toBe('')
    expect(takeDeferredAnchor(tree)).toBe(anchor)
    expect(takeDeferredAnchor(tree)).toBeUndefined()
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

    expect(result).toBe(fallback)
    expect(failed).toHaveBeenCalled()
    expect(tree.dataset.saveState).toBe('error')
  })
})
