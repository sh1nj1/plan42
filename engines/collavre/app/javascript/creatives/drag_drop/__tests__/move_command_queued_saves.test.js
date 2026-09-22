/** @jest-environment jsdom */
import { jest } from '@jest/globals'
import { apiQueue } from '../../../lib/api/queue_manager'
import { executeMoveCommand } from '../move_command'

const intent = { ids: ['42'], targetId: '20', direction: 'child' }
const tick = async () => { for (let i = 0; i < 10; i++) await Promise.resolve() }
function deferred() {
  let resolve, reject
  const promise = new Promise((yes, no) => { resolve = yes; reject = no })
  return { promise, resolve, reject }
}
function enqueue(id = '42') {
  apiQueue.enqueue({ path: `/creatives/${id}`, method: 'PATCH', dedupeKey: `creative_${id}`,
    body: { 'creative[description]': 'edited', 'creative[parent_id]': '10' } })
}

describe('moves with queued edits', () => {
  let sendNewOrder
  beforeEach(() => {
    apiQueue.clear()
    apiQueue.processing = false
    localStorage.clear()
    apiQueue.initialize('move-test')
    sendNewOrder = jest.fn().mockResolvedValue({ ok: true, status: 200 })
    jest.spyOn(console, 'error').mockImplementation(() => {})
  })
  afterEach(() => { jest.restoreAllMocks(); apiQueue.clear() })
  const move = (command = intent) => executeMoveCommand(command, { api: { sendNewOrder } })

  test('a delayed PATCH lands before the cross-parent move', async () => {
    const save = deferred()
    let parent = '10'
    jest.spyOn(apiQueue, 'executeRequest').mockImplementation(async item => {
      await save.promise
      parent = item.body['creative[parent_id]']
    })
    sendNewOrder.mockImplementation(async () => { parent = '20'; return { ok: true } })
    enqueue()
    const result = move()
    await tick()
    expect(sendNewOrder).not.toHaveBeenCalled()
    save.resolve()
    expect((await result).ok).toBe(true)
    expect(parent).toBe('20')
  })

  test('waits for every selected row and the destination, including later snapshots', async () => {
    const saves = [deferred(), deferred(), deferred(), deferred()]
    const execute = jest.spyOn(apiQueue, 'executeRequest')
    saves.forEach(save => execute.mockImplementationOnce(() => save.promise))
    enqueue('42'); enqueue('43'); enqueue('20')
    const result = move({ ...intent, ids: ['42', '43'] })
    enqueue('42')
    for (const save of saves) {
      await tick()
      expect(sendNewOrder).not.toHaveBeenCalled()
      save.resolve()
    }
    expect((await result).ok).toBe(true)
    expect(sendNewOrder).toHaveBeenCalledTimes(1)
  })

  test('a permanent save failure prevents the whole move', async () => {
    const save = deferred()
    jest.spyOn(apiQueue, 'executeRequest').mockImplementation(() => save.promise)
    enqueue()
    const result = move({ ...intent, ids: ['42', '43'] })
    save.reject(Object.assign(new Error('Forbidden'), { status: 403 }))
    expect(await result).toMatchObject({ ok: false, failedIds: ['42', '43'] })
    expect(sendNewOrder).not.toHaveBeenCalled()
    expect(apiQueue.failedItems).toHaveLength(1)
  })

  test.each(['Validation failed', undefined])('an already failed draft blocks movement: %s', async lastError => {
    apiQueue.failedItems = [{ dedupeKey: 'creative_42', lastError }]
    expect((await move()).ok).toBe(false)
    expect(sendNewOrder).not.toHaveBeenCalled()
  })

  test('successful retry clears the failure and permits movement', async () => {
    apiQueue.failedItems = [{ dedupeKey: 'creative_42', timestamp: 1 }]
    jest.spyOn(apiQueue, 'executeRequest').mockResolvedValue(undefined)
    enqueue()
    expect((await move()).ok).toBe(true)
    expect(apiQueue.failedItems).toEqual([])
  })

  test('unrelated offline and failed drafts do not block movement', async () => {
    apiQueue.queue = [{ dedupeKey: 'creative_99' }]
    apiQueue.failedItems = [{ dedupeKey: 'creative_98' }]
    expect((await move()).ok).toBe(true)
  })

  test('persisted offline requests delay movement until processing resumes', async () => {
    apiQueue.queue = [{ dedupeKey: 'creative_42', body: { 'creative[parent_id]': '10' } }]
    apiQueue.saveToLocalStorage()
    apiQueue.initialize('move-test')
    const result = move()
    await tick()
    expect(sendNewOrder).not.toHaveBeenCalled()
    jest.spyOn(apiQueue, 'executeRequest').mockResolvedValue(undefined)
    await apiQueue.processQueue()
    expect((await result).ok).toBe(true)
  })
})
