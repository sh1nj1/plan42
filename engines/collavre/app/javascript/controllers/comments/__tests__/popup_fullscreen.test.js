/**
 * @jest-environment jsdom
 */

import { jest } from '@jest/globals'
import PopupFullscreen from '../popup_fullscreen'

describe('PopupFullscreen', () => {
  let element
  let manager
  let callbacks
  let requestAnimationFrame
  let listController

  beforeEach(() => {
    jest.useFakeTimers()
    document.body.innerHTML = '<div id="popup"></div>'
    document.body.className = ''
    element = document.getElementById('popup')
    element.dataset.creativeId = '42'
    requestAnimationFrame = jest
      .spyOn(globalThis, 'requestAnimationFrame')
      .mockImplementation(callback => {
        callback()
        return 1
      })
    listController = { scrollToBottom: jest.fn() }
    callbacks = {
      isMobile: jest.fn(() => false),
      isDocked: jest.fn(() => false),
      syncUi: jest.fn(),
      syncDockedUi: jest.fn(),
      getListController: jest.fn(() => listController),
      getTopicsController: jest.fn(() => ({ scrollToActiveTopic: jest.fn() })),
      getCurrentButton: jest.fn(() => null),
      setCurrentButton: jest.fn(),
    }
    manager = new PopupFullscreen({ element, ...callbacks })
    window.history.replaceState({}, '', '/creatives/42')
  })

  afterEach(() => {
    manager.cancelEnterCleanup()
    requestAnimationFrame.mockRestore()
    jest.useRealTimers()
  })

  test('owns fullscreen entry state and browser history', () => {
    element.style.top = '12px'
    element.style.right = '20px'
    element.style.width = '300px'
    element.style.height = '400px'
    jest.spyOn(element, 'getBoundingClientRect').mockReturnValue({
      top: 12,
      left: 704,
      width: 300,
      height: 400,
    })

    manager.enter()

    expect(manager.savedStyles).toEqual({
      top: '12px',
      right: '20px',
      left: '',
      width: '300px',
      height: '400px',
    })
    expect(element.dataset.fullscreen).toBe('true')
    expect(document.body.classList.contains('chat-fullscreen')).toBe(true)
    expect(callbacks.syncUi).toHaveBeenCalledWith(true)
    expect(window.location.pathname).toBe('/creatives/42/comments/fullscreen')
    expect(listController.scrollToBottom).toHaveBeenCalledTimes(1)
  })

  test('restores the mobile popup and keeps it open in the URL', () => {
    callbacks.isMobile.mockReturnValue(true)
    element.dataset.fullscreen = 'true'
    element.style.position = 'fixed'
    element.style.transform = 'scale(1)'
    document.body.classList.add('chat-fullscreen')
    manager.previousUrl = '/creatives/42?comment_id=7'

    manager.exit()

    expect(element.dataset.fullscreen).toBe('false')
    expect(element.style.position).toBe('')
    expect(element.style.transform).toBe('')
    expect(document.body.classList.contains('chat-fullscreen')).toBe(false)
    expect(callbacks.syncUi).toHaveBeenCalledWith(false)
    expect(window.location.pathname).toBe('/creatives/42')
    expect(new URLSearchParams(window.location.search).get('open_comments')).toBe('true')
    expect(new URLSearchParams(window.location.search).get('comment_id')).toBe('7')
    expect(listController.scrollToBottom).toHaveBeenCalledTimes(1)
  })

  test('cleans deep-link markers when fullscreen is closed', () => {
    element.dataset.fullscreen = 'true'
    document.body.classList.add('chat-fullscreen')
    manager.previousUrl = '/creatives/42/comments/77?open_comments=true&comment_id=77#comment_77'

    manager.exitState()

    expect(element.dataset.fullscreen).toBe('false')
    expect(document.body.classList.contains('chat-fullscreen')).toBe(false)
    expect(window.location.pathname).toBe('/creatives/42')
    expect(window.location.search).toBe('')
    expect(window.location.hash).toBe('')
    expect(manager.previousUrl).toBeNull()
  })

  test('restores docked UI when browser navigation exits fullscreen', () => {
    callbacks.isDocked.mockReturnValue(true)
    element.dataset.fullscreen = 'true'
    element.style.display = 'none'
    manager.savedStyles = { width: '320px', height: '480px' }

    manager.handlePopState({ state: { fullscreen: false } })

    expect(element.dataset.fullscreen).toBe('false')
    expect(element.style.display).toBe('flex')
    expect(element.style.width).toBe('320px')
    expect(element.style.height).toBe('480px')
    expect(callbacks.syncDockedUi).toHaveBeenCalledTimes(1)
    expect(manager.savedStyles).toBeNull()
  })

  test('enters fullscreen without animation or history for auto-fullscreen', () => {
    element.style.position = 'fixed'
    element.style.top = '12px'
    element.style.width = '300px'

    manager.enterImmediate()

    expect(element.dataset.fullscreen).toBe('true')
    expect(document.body.classList.contains('chat-fullscreen')).toBe(true)
    expect(callbacks.syncUi).toHaveBeenCalledWith(true)
    expect(element.style.position).toBe('')
    expect(element.style.top).toBe('')
    expect(element.style.width).toBe('')
    expect(window.location.pathname).toBe('/creatives/42')
    expect(listController.scrollToBottom).toHaveBeenCalledTimes(1)
  })

  test('drops the entry animation styles once the transition settles', () => {
    jest.spyOn(element, 'getBoundingClientRect').mockReturnValue({
      top: 12,
      left: 704,
      width: 300,
      height: 400,
    })

    manager.enter()
    expect(element.style.position).toBe('fixed')

    jest.advanceTimersByTime(300)

    expect(element.style.position).toBe('')
    expect(element.style.top).toBe('')
    expect(element.style.height).toBe('')
    expect(manager.enterCleanupTimer).toBeNull()
    expect(manager.enterCleanupFn).toBeNull()
  })

  test('returns the docked popup to its dock without animation', () => {
    callbacks.isDocked.mockReturnValue(true)
    element.dataset.fullscreen = 'true'
    element.style.position = 'fixed'
    element.style.top = '0'
    document.body.classList.add('chat-fullscreen')
    manager.savedStyles = { width: '320px', height: '480px' }

    manager.exit()

    expect(element.dataset.fullscreen).toBe('false')
    expect(element.style.position).toBe('')
    expect(element.style.top).toBe('')
    expect(document.body.classList.contains('chat-fullscreen')).toBe(false)
    expect(callbacks.syncUi).toHaveBeenCalledWith(false)
    expect(callbacks.syncDockedUi).toHaveBeenCalledTimes(1)
    expect(manager.savedStyles).toBeNull()
    expect(window.location.pathname).toBe('/creatives/42')
    expect(new URLSearchParams(window.location.search).get('open_comments')).toBe('true')
    expect(listController.scrollToBottom).toHaveBeenCalledTimes(1)
  })

  test('lands the desktop popup to the right of its trigger button when there is room', () => {
    const button = document.createElement('button')
    document.body.appendChild(button)
    jest.spyOn(button, 'getBoundingClientRect').mockReturnValue({
      top: 30,
      bottom: 50,
      left: 60,
      right: 100,
      width: 40,
      height: 20,
    })
    callbacks.getCurrentButton.mockReturnValue(button)
    jest.spyOn(element, 'getBoundingClientRect').mockReturnValue({
      top: 0,
      left: 0,
      width: 1024,
      height: 768,
    })
    element.dataset.fullscreen = 'true'
    document.body.classList.add('chat-fullscreen')
    manager.savedStyles = { top: '', right: '', left: '', width: '300px', height: '400px' }

    manager.exit()

    expect(callbacks.setCurrentButton).toHaveBeenCalledWith(button)
    expect(element.dataset.fullscreen).toBe('false')
    expect(element.style.left).toBe('108px')

    jest.advanceTimersByTime(300)

    expect(element.style.top).toBe('54px')
    expect(element.style.width).toBe('300px')
    expect(element.style.height).toBe('400px')
    expect(element.style.left).toBe('108px')
    expect(element.style.right).toBe('')
  })

  test('anchors to the right edge and clamps the top when the button sits low and far right', () => {
    const button = document.createElement('button')
    document.body.appendChild(button)
    jest.spyOn(button, 'getBoundingClientRect').mockReturnValue({
      top: 580,
      bottom: 600,
      left: 960,
      right: 1000,
      width: 40,
      height: 20,
    })
    callbacks.getCurrentButton.mockReturnValue(button)
    jest.spyOn(element, 'getBoundingClientRect').mockReturnValue({
      top: 0,
      left: 0,
      width: 1024,
      height: 768,
    })
    element.dataset.fullscreen = 'true'
    manager.savedStyles = { top: '', right: '', left: '', width: '300px', height: '400px' }

    manager.exit()
    jest.advanceTimersByTime(300)

    // 600 + 4 + 400 overflows 768, so the top clamps to innerHeight - height - 4.
    expect(element.style.top).toBe('364px')
    expect(element.style.right).toBe('48px')
    expect(element.style.left).toBe('')
    expect(element.style.width).toBe('300px')
  })

  test('falls back to default popup geometry when no button or saved styles exist', () => {
    const topicsController = { scrollToActiveTopic: jest.fn() }
    callbacks.getTopicsController.mockReturnValue(topicsController)
    jest.spyOn(element, 'getBoundingClientRect').mockReturnValue({
      top: 0,
      left: 0,
      width: 1024,
      height: 768,
    })
    element.dataset.fullscreen = 'true'
    manager.savedStyles = null

    manager.exit()

    expect(element.style.left).toBe('572px')
    expect(element.style.width).toBe('420px')
    expect(element.style.height).toBe('640px')

    jest.advanceTimersByTime(300)

    expect(element.style.position).toBe('')
    expect(element.style.left).toBe('')
    expect(element.style.width).toBe('')
    expect(topicsController.scrollToActiveTopic).toHaveBeenCalledTimes(1)
  })

  test('toggle enters when windowed and exits when already fullscreen', () => {
    jest.spyOn(element, 'getBoundingClientRect').mockReturnValue({
      top: 12,
      left: 704,
      width: 300,
      height: 400,
    })

    manager.toggle()
    expect(manager.active).toBe(true)
    expect(window.location.pathname).toBe('/creatives/42/comments/fullscreen')

    manager.toggle()
    expect(manager.active).toBe(false)
  })
})
