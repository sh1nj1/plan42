/**
 * @jest-environment jsdom
 */

import { jest } from '@jest/globals'

// Every topic mutation used to alert a hardcoded English literal on failure.
// These tests pin that each failure path reaches the user through the localized
// string handed down by the ERB partial, and that the English literals survive
// only as the last-resort fallback when the partial supplied nothing.
jest.unstable_mockModule('../../../lib/utils/dialog', () => ({
  confirmDialog: jest.fn(),
  alertDialog: jest.fn(),
}))

const { Application } = await import('@hotwired/stimulus')
const TopicsController = (await import('../topics_controller')).default
const { alertDialog, confirmDialog } = await import('../../../lib/utils/dialog')

// Mirrors the data attributes emitted by _comments_popup.html.erb.
const LOCALIZED = {
  topicSetAgentError: '에이전트를 지정할 수 없습니다.',
  topicCreateError: '토픽을 만들 수 없습니다.',
  topicUpdateError: '토픽을 수정할 수 없습니다.',
  topicDeleteError: '토픽을 삭제할 수 없습니다.',
  topicArchiveError: '토픽을 보관할 수 없습니다.',
  topicRestoreError: '토픽을 복원할 수 없습니다.',
}

const ENGLISH_FALLBACK = {
  set_agent_error: 'Unable to assign the agent to this topic.',
  create_error: 'Unable to create the topic.',
  update_error: 'Unable to update the topic.',
  delete_error: 'Unable to delete the topic.',
  archive_error: 'Unable to archive the topic.',
  restore_error: 'Unable to restore the topic.',
}

describe('TopicsController topic action failures', () => {
  let application
  let controller
  let element

  const mount = async (dataset = LOCALIZED) => {
    const container = document.createElement('div')
    container.innerHTML = `
      <div id="topics" data-controller="comments--topics">
        <div data-comments--topics-target="list"></div>
      </div>
    `
    document.body.appendChild(container)

    element = document.getElementById('topics')
    Object.assign(element.dataset, dataset)

    application = Application.start()
    application.register('comments--topics', TopicsController)

    const meta = document.createElement('meta')
    meta.name = 'csrf-token'
    meta.content = 'test-csrf'
    document.head.appendChild(meta)

    await new Promise((resolve) => setTimeout(resolve, 0))
    controller = application.getControllerForElementAndIdentifier(element, 'comments--topics')
    controller.creativeIdValue = '42'
    controller.loadTopics = jest.fn()
    controller.renderTopics = jest.fn()
    controller.restoreSelection = jest.fn()
    controller.flushSaveLastTopic = jest.fn()
    controller.topics = [{ id: 1, name: 'Main' }]
    return controller
  }

  // deleteTopic/archiveTopic/unarchiveTopic read the id off event.currentTarget.
  const eventFor = (id) => ({
    stopPropagation: jest.fn(),
    currentTarget: { dataset: { id: String(id) } },
  })

  const failingFetch = () => jest.fn().mockResolvedValue({ ok: false, json: async () => ({}) })

  afterEach(() => {
    document.body.innerHTML = ''
    document.head.innerHTML = ''
    application.stop()
    jest.clearAllMocks()
  })

  describe('with localized strings from the partial', () => {
    beforeEach(async () => {
      await mount()
      confirmDialog.mockResolvedValue(true)
    })

    test('deleteTopic surfaces the localized delete error', async () => {
      global.fetch = failingFetch()
      controller.serverLastTopicId = '1'
      controller._topicScrollInterrupted = true

      await controller.deleteTopic(eventFor(1))

      expect(alertDialog).toHaveBeenCalledWith(LOCALIZED.topicDeleteError)
      expect(controller._topicScrollInterrupted).toBe(true)
    })

    test('archiveTopic surfaces the localized archive error', async () => {
      global.fetch = failingFetch()
      controller.serverLastTopicId = '1'
      controller._topicScrollInterrupted = true

      await controller.archiveTopic(eventFor(1))

      expect(alertDialog).toHaveBeenCalledWith(LOCALIZED.topicArchiveError)
      expect(controller._topicScrollInterrupted).toBe(true)
    })

    test('unarchiveTopic surfaces the localized restore error', async () => {
      global.fetch = failingFetch()

      await controller.unarchiveTopic(eventFor(1))

      expect(alertDialog).toHaveBeenCalledWith(LOCALIZED.topicRestoreError)
    })

    // updateTopic additionally reloads to discard the optimistic rename.
    test('updateTopic surfaces the localized update error and reloads', async () => {
      global.fetch = failingFetch()

      await controller.updateTopic('1', 'Renamed')

      expect(alertDialog).toHaveBeenCalledWith(LOCALIZED.topicUpdateError)
      expect(controller.loadTopics).toHaveBeenCalled()
    })

    test('createTopic surfaces the localized create error', async () => {
      global.fetch = failingFetch()

      await controller.createTopic('New topic')

      expect(alertDialog).toHaveBeenCalledWith(LOCALIZED.topicCreateError)
      // The `finally` block must clear the guard even on the failure path,
      // otherwise blur handling stays wedged after one failed create.
      expect(controller.creating).toBe(false)
    })
  })

  describe('without localized strings (controller mounted bare)', () => {
    beforeEach(async () => {
      await mount({})
      confirmDialog.mockResolvedValue(true)
    })

    test.each(Object.entries(ENGLISH_FALLBACK))(
      '_i18n("%s") falls back to the English literal',
      (key, expected) => {
        expect(controller._i18n(key)).toBe(expected)
      }
    )

    // An unknown key must not render as `undefined` in a dialog; returning the
    // key itself keeps the failure legible.
    test('_i18n returns the key itself when it is unknown', () => {
      expect(controller._i18n('no_such_key')).toBe('no_such_key')
    })
  })

  describe('_i18n with localized strings', () => {
    beforeEach(async () => {
      await mount()
    })

    test.each([
      ['set_agent_error', LOCALIZED.topicSetAgentError],
      ['create_error', LOCALIZED.topicCreateError],
      ['update_error', LOCALIZED.topicUpdateError],
      ['delete_error', LOCALIZED.topicDeleteError],
      ['archive_error', LOCALIZED.topicArchiveError],
      ['restore_error', LOCALIZED.topicRestoreError],
    ])('_i18n("%s") prefers the value from the partial', (key, expected) => {
      expect(controller._i18n(key)).toBe(expected)
    })
  })
})
