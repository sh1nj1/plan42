/**
 * @jest-environment jsdom
 */

import { jest } from '@jest/globals'
import {
  findPopupTargetButton,
  popupExitTarget,
  restorePopupTargetStyles,
} from '../popup_exit_target'

describe('popup exit target', () => {
  test('finds and reveals the creative row button when the current button is missing', () => {
    document.body.innerHTML = `
      <creative-tree-row creative-id="42">
        <button class="comments-btn"></button>
      </creative-tree-row>
    `
    const row = document.querySelector('creative-tree-row')
    row.scrollIntoView = jest.fn()

    const button = findPopupTargetButton(null, '42')

    expect(button).toBe(document.querySelector('.comments-btn'))
    expect(row.scrollIntoView).toHaveBeenCalledWith({ behavior: 'instant', block: 'center' })
  })

  test('places the popup beside a button when the viewport has room', () => {
    const targetButton = document.createElement('button')
    targetButton.getBoundingClientRect = () => ({ bottom: 50, right: 100 })

    const target = popupExitTarget({
      targetButton,
      savedStyles: { width: '300px', height: '400px' },
      viewport: { width: 1024, height: 768 },
    })

    expect(target).toMatchObject({
      finalTop: '54px',
      finalRight: '',
      animTop: 54,
      animLeft: 108,
      animWidth: 300,
      animHeight: 400,
      exitToRight: true,
    })
  })

  test('anchors to the right edge and clamps a low button target', () => {
    const targetButton = document.createElement('button')
    targetButton.getBoundingClientRect = () => ({ bottom: 600, right: 1000 })

    const target = popupExitTarget({
      targetButton,
      savedStyles: { width: '300px', height: '400px' },
      viewport: { width: 1024, height: 768 },
    })

    expect(target).toMatchObject({
      finalTop: '364px',
      finalRight: '48px',
      animTop: 364,
      animLeft: 676,
      exitToRight: false,
    })
  })

  test('uses saved geometry when no target button is available', () => {
    const target = popupExitTarget({
      targetButton: null,
      savedStyles: { top: '72px', right: '24px', left: '', width: '360px', height: '480px' },
      viewport: { width: 1024, height: 768 },
    })

    expect(target).toMatchObject({
      finalTop: '72px',
      finalRight: '24px',
      animTop: 72,
      animLeft: 640,
      animWidth: 360,
      animHeight: 480,
    })
  })

  test('falls back to the default popup geometry', () => {
    const target = popupExitTarget({
      targetButton: null,
      savedStyles: null,
      viewport: { width: 1024, height: 768 },
    })

    expect(target).toMatchObject({
      finalTop: '',
      finalRight: '',
      finalWidth: '',
      finalHeight: '',
      animTop: 100,
      animLeft: 572,
      animWidth: 420,
      animHeight: 640,
    })
  })

  test.each([
    [{ exitToRight: true, animLeft: 108, finalTop: '54px', finalWidth: '300px', finalHeight: '400px' }, { top: '54px', left: '108px', right: '' }],
    [{ exitToRight: false, finalRight: '48px', finalTop: '364px', finalWidth: '300px', finalHeight: '400px' }, { top: '364px', left: '', right: '48px' }],
  ])('restores target styles for either horizontal anchor', (target, expected) => {
    const style = document.createElement('div').style

    restorePopupTargetStyles(style, target)

    expect(style.top).toBe(expected.top)
    expect(style.left).toBe(expected.left)
    expect(style.right).toBe(expected.right)
    expect(style.width).toBe('300px')
    expect(style.height).toBe('400px')
  })
})
