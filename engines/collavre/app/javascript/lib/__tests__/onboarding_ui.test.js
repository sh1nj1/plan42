/** @jest-environment jsdom */
import { jest } from '@jest/globals'
import { openInitialChat } from '../onboarding_ui'

describe('initial chat layout precedence', () => {
  test('fullscreen opens after controller connection and takes precedence over docking', () => {
    const frame = jest.spyOn(window, 'requestAnimationFrame').mockImplementation(() => 1)
    const controller = {
      isFullscreen: () => true,
      isDocked: () => true,
      _syncFullscreenUI: jest.fn(),
      openForCreative: jest.fn(),
      enterDockedMode: jest.fn(),
    }
    openInitialChat(controller)
    expect(controller._syncFullscreenUI).toHaveBeenCalledWith(true)
    expect(controller.openForCreative).not.toHaveBeenCalled()
    expect(controller.enterDockedMode).not.toHaveBeenCalled()
    frame.mock.calls[0][0]()
    expect(controller.openForCreative).toHaveBeenCalledTimes(1)
    frame.mockRestore()
  })

  test('floating chat uses the URL only without a pending onboarding open', () => {
    const controller = {
      isFullscreen: () => false, isDocked: () => false,
      openPendingChat: jest.fn(() => false), openFromUrl: jest.fn(),
    }
    openInitialChat(controller)
    expect(controller.openFromUrl).toHaveBeenCalledTimes(1)
    controller.openPendingChat.mockReturnValue(true)
    openInitialChat(controller)
    expect(controller.openFromUrl).toHaveBeenCalledTimes(1)
  })

  test('docking takes precedence over an onboarding auto-open', () => {
    const controller = {
      isFullscreen: () => false,
      isDocked: () => true,
      enterDockedMode: jest.fn(),
      openPendingChat: jest.fn(),
    }
    openInitialChat(controller)
    expect(controller.enterDockedMode).toHaveBeenCalledTimes(1)
    expect(controller.openPendingChat).not.toHaveBeenCalled()
  })
})
