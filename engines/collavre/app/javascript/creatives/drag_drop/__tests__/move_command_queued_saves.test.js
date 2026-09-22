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

  test.each(['42', '20'])('rechecks %s when a new save arrives while another row is pending', async id => {
    const saves = [deferred(), deferred(), deferred()]
    let parent = '10'
    const execute = jest.spyOn(apiQueue, 'executeRequest')
    saves.forEach(save => execute.mockImplementationOnce(async item => {
      await save.promise
      if (item.dedupeKey === `creative_${id}`) parent = item.body['creative[parent_id]']
    }))
    sendNewOrder.mockImplementation(async () => { parent = '20'; return { ok: true } })
    enqueue(id); enqueue('43')
    const result = move({ ...intent, ids: ['42', '43'] })
    saves[0].resolve()
    await tick()
    enqueue(id)
    saves[1].resolve()
    await tick()
    expect(sendNewOrder).not.toHaveBeenCalled()
    saves[2].resolve()
    expect((await result).ok).toBe(true)
    expect(parent).toBe('20')
  })

  test('a new save failure after an earlier wait completed prevents movement', async () => {
    const saves = [deferred(), deferred(), deferred()]
    const execute = jest.spyOn(apiQueue, 'executeRequest')
    saves.forEach(save => execute.mockImplementationOnce(() => save.promise))
    enqueue('42'); enqueue('43')
    const result = move({ ...intent, ids: ['42', '43'] })
    saves[0].resolve()
    await tick()
    enqueue('42')
    saves[1].resolve()
    await tick()
    saves[2].reject(Object.assign(new Error('Forbidden'), { status: 403 }))
    expect(await result).toMatchObject({ ok: false, failedIds: ['42', '43'] })
    expect(sendNewOrder).not.toHaveBeenCalled()
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

  test.each(['up', 'down', 'child'])('link drop %s waits for the target move to finish', async direction => {
    const save = deferred()
    let targetParent = '10'
    jest.spyOn(apiQueue, 'executeRequest').mockImplementation(async () => {
      await save.promise
      targetParent = '30'
    })
    const sendLinkedCreative = jest.fn(async () => ({ parent_id: targetParent }))
    enqueue('20')
    const result = executeMoveCommand({ ...intent, direction, mode: 'link' }, { api: { sendLinkedCreative } })
    await tick()
    expect(sendLinkedCreative).not.toHaveBeenCalled()
    save.resolve()
    expect(await result).toMatchObject({ ok: true, payloads: [{ id: '42', data: { parent_id: '30' } }] })
  })

  test('each link waits for target saves added after the preceding link', async () => {
    const save = deferred()
    jest.spyOn(apiQueue, 'executeRequest').mockImplementation(() => save.promise)
    const sendLinkedCreative = jest.fn().mockImplementationOnce(async () => {
      enqueue('20')
      return { id: 'link-43' }
    }).mockResolvedValue({ id: 'link-42' })
    const result = executeMoveCommand({ ...intent, ids: ['42', '43'], direction: 'down', mode: 'link' },
      { api: { sendLinkedCreative } })
    await tick()
    expect(sendLinkedCreative).toHaveBeenCalledTimes(1)
    expect(sendLinkedCreative).toHaveBeenNthCalledWith(1, { draggedId: '43', targetId: '20', direction: 'down' })
    save.resolve()
    expect(await result).toMatchObject({ ok: true, succeededIds: ['42', '43'] })
    expect(sendLinkedCreative).toHaveBeenCalledTimes(2)
  })

  test('a target save failure prevents every sibling link request', async () => {
    const save = deferred()
    jest.spyOn(apiQueue, 'executeRequest').mockImplementation(() => save.promise)
    const sendLinkedCreative = jest.fn()
    enqueue('20')
    const result = executeMoveCommand({ ...intent, ids: ['42', '43'], direction: 'up', mode: 'link' },
      { api: { sendLinkedCreative } })
    save.reject(Object.assign(new Error('Forbidden'), { status: 403 }))
    expect(await result).toMatchObject({ ok: false, failedIds: ['42', '43'], succeededIds: [] })
    expect(sendLinkedCreative).not.toHaveBeenCalled()
  })

  test('a target save failure between links preserves partial success', async () => {
    const sendLinkedCreative = jest.fn(async () => {
      apiQueue.failedItems = [{ dedupeKey: 'creative_20', lastError: 'Forbidden' }]
      return { id: 'link-42' }
    })
    const result = await executeMoveCommand({ ...intent, ids: ['42', '43'], direction: 'up', mode: 'link' },
      { api: { sendLinkedCreative } })
    expect(result).toMatchObject({ status: 'partial', succeededIds: ['42'], failedIds: ['43'] })
    expect(sendLinkedCreative).toHaveBeenCalledTimes(1)
  })

})
