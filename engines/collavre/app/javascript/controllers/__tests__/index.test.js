/**
 * @jest-environment jsdom
 */

import { jest } from '@jest/globals'
import LastVisitedCreativeController from '../last_visited_creative_controller'

describe('registerControllers', () => {
  test('registers the last-visited Creative controller', async () => {
    jest.unstable_mockModule('@hotwired/turbo-rails', () => ({ Turbo: {} }))
    for (const controller of [
      '../comment_controller',
      '../comment_version_controller',
      '../link_creative_controller',
      '../topic_search_controller',
      '../topic_list_controller',
      '../share_modal_controller',
      '../share_user_search_controller',
      '../inbox_badge_controller',
      '../creatives/drag_drop_controller',
      '../creatives/row_editor_controller',
      '../creatives/tree_controller',
      '../creatives/sync_controller',
      '../comments/list_controller',
      '../comments/form_controller',
      '../comments/presence_controller',
      '../comments/topics_controller',
      '../comments/popup_controller',
    ]) {
      jest.unstable_mockModule(controller, () => ({ default: class {} }))
    }
    const { registerControllers } = await import('../index')
    const application = { register: jest.fn() }

    registerControllers(application)

    expect(application.register).toHaveBeenCalledWith(
      'last-visited-creative',
      LastVisitedCreativeController,
    )
    expect(application.register).toHaveBeenCalledWith(
      'cron-badge',
      expect.any(Function),
    )
  })
})
