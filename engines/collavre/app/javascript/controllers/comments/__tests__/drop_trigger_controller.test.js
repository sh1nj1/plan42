import { jest } from '@jest/globals'
import DropTriggerController from '../drop_trigger_controller'

describe('drop trigger state loading', () => {
  let controller
  let originalFetch

  beforeEach(() => {
    controller = Object.create(DropTriggerController.prototype)
    controller._creativeId = '42'
    controller._updateUI = jest.fn()
    originalFetch = global.fetch
  })

  afterEach(() => { global.fetch = originalFetch })

  test('loads container permissions and trigger setting', async () => {
    global.fetch = jest.fn().mockResolvedValue({ ok: true, json: async () => ({
      can_edit: true, data: { trigger: { on_child_enter: true } }
    }) })
    await controller._loadTriggerState()
    expect(global.fetch).toHaveBeenCalledWith('/creatives/42.json', { cache: 'no-store' })
    expect(controller.canWrite).toBe(true)
    expect(controller.enabled).toBe(true)
    expect(controller._role).toBe('container')
    expect(controller._updateUI).toHaveBeenCalledTimes(1)
  })

  test('loads task state without a data object', async () => {
    global.fetch = jest.fn().mockResolvedValue({ ok: true, json: async () => ({
      is_trigger_task: true, trigger_loop: { state: 'paused', current_iteration: 2, max_iterations: 4 }
    }) })
    await controller._loadTriggerState()
    expect(controller._role).toBe('task')
    expect(controller._loopState).toBe('paused')
    expect(controller._loopIteration).toBe(2)
    expect(controller._loopMax).toBe(4)
    expect(controller.canWrite).toBe(false)
  })

  test('non-OK load preserves existing state', async () => {
    controller._role = 'task'
    global.fetch = jest.fn().mockResolvedValue({ ok: false })
    await controller._loadTriggerState()
    expect(controller._role).toBe('task')
    expect(controller._updateUI).not.toHaveBeenCalled()
  })
})
