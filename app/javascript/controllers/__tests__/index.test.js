import { jest } from '@jest/globals'
import { registerControllers as registerTranslationControllers } from '../../../../engines/collavre_translation/app/javascript/controllers/index.js'
import CommentTranslationController from '../../../../engines/collavre_translation/app/javascript/controllers/comment_translation_controller.js'

describe('host controller registration', () => {
  test('registers the translation controller on the host Stimulus application', async () => {
    const application = { register: jest.fn() }
    jest.unstable_mockModule('../application', () => ({ application }))
    jest.unstable_mockModule('collavre/controllers', () => ({ registerControllers: jest.fn() }))
    jest.unstable_mockModule('collavre_plan/controllers', () => ({ registerControllers: jest.fn() }), { virtual: true })
    jest.unstable_mockModule('collavre_translation/controllers', () => ({ registerControllers: registerTranslationControllers }), { virtual: true })
    for (const controller of ['avatar_preview', 'llm_model', 'webauthn']) {
      jest.unstable_mockModule(`../${controller}_controller`, () => ({ default: class {} }))
    }

    await import('../index.js')

    expect(application.register).toHaveBeenCalledWith('comment-translation', CommentTranslationController)
    expect(application.register).toHaveBeenCalledWith('avatar-preview', expect.any(Function))
    expect(application.register).toHaveBeenCalledWith('llm-model', expect.any(Function))
    expect(application.register).toHaveBeenCalledWith('webauthn', expect.any(Function))
  })
})
