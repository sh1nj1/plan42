/**
 * @jest-environment jsdom
 */

import { jest } from '@jest/globals'
import {
  insertMarkdownCreativeLink,
  markdownCreativeCommandRange,
  openCreativeLinkPicker,
} from '../creative_link_picker'

describe('creative link picker helpers', () => {
  afterEach(() => {
    document.body.innerHTML = ''
    delete window.Stimulus
  })

  test('finds /creative only at the beginning of a Markdown line', () => {
    expect(markdownCreativeCommandRange('/creative', 9)).toEqual({ start: 0, end: 9 })
    expect(markdownCreativeCommandRange('first\n/creative', 15)).toEqual({ start: 6, end: 15 })
    expect(markdownCreativeCommandRange('text /creative', 14)).toBeNull()
    expect(markdownCreativeCommandRange('/creative later', 15)).toBeNull()
  })

  test('inserts the canonical Markdown link and notifies textarea consumers', () => {
    const textarea = document.createElement('textarea')
    textarea.value = 'before after'
    textarea.setSelectionRange(7, 7)
    const inputListener = jest.fn()
    textarea.addEventListener('input', inputListener)

    expect(insertMarkdownCreativeLink(textarea, { id: 12, label: 'Target' })).toBe(true)
    expect(textarea.value).toBe('before [Target](/creatives/12) after')
    expect(inputListener).toHaveBeenCalledTimes(1)
  })

  test('removes the trigger and opens the shared picker with creation enabled', () => {
    document.body.innerHTML = '<div id="link-creative-modal"></div><textarea id="editor">/creative</textarea>'
    const textarea = document.getElementById('editor')
    textarea.setSelectionRange(9, 9)
    const controller = { open: jest.fn() }
    window.Stimulus = {
      getControllerForElementAndIdentifier: jest.fn(() => controller),
    }

    const opened = openCreativeLinkPicker(textarea, {
      triggerRange: { start: 0, end: 9 },
    })

    expect(opened).toBe(true)
    expect(textarea.value).toBe('')
    expect(controller.open).toHaveBeenCalledTimes(1)
    expect(controller.open.mock.calls[0][3]).toEqual({ allowCreate: true })

    controller.open.mock.calls[0][1]({ id: 18, label: 'Created' })
    expect(textarea.value).toBe('[Created](/creatives/18) ')
  })

  test('does not remove the trigger when the shared picker is unavailable', () => {
    document.body.innerHTML = '<textarea id="editor">/creative</textarea>'
    const textarea = document.getElementById('editor')
    textarea.setSelectionRange(9, 9)

    expect(openCreativeLinkPicker(textarea, {
      triggerRange: { start: 0, end: 9 },
    })).toBe(false)
    expect(textarea.value).toBe('/creative')
  })
})
