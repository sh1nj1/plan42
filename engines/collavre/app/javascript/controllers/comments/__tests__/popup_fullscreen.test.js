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
})
