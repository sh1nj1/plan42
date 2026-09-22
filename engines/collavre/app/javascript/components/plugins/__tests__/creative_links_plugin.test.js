/** @jest-environment jsdom */
import { jest } from '@jest/globals'
import React, { act } from 'react'
import { createRoot } from 'react-dom/client'
import { LexicalComposer } from '@lexical/react/LexicalComposer'

const cleanupDrop = jest.fn()
const cleanupTrigger = jest.fn()
const registerDrop = jest.fn(() => cleanupDrop)
const registerTrigger = jest.fn(() => cleanupTrigger)
jest.unstable_mockModule('../../../lib/lexical/creative_link_drop', () => ({ registerCreativeLinkDrop: registerDrop }))
jest.unstable_mockModule('../../../lib/lexical/creative_link_trigger', () => ({ registerCreativeLinkTrigger: registerTrigger }))
const { default: CreativeLinksPlugin } = await import('../creative_links_plugin')

let root
beforeEach(async () => {
  jest.clearAllMocks()
  globalThis.IS_REACT_ACT_ENVIRONMENT = true
  document.body.innerHTML = '<div id="editor"></div>'
  root = createRoot(document.getElementById('editor'))
  await act(async () => root.render(React.createElement(LexicalComposer, {
    initialConfig: { namespace: 'plugin-test', onError: error => { throw error } }
  }, React.createElement(CreativeLinksPlugin))))
})
afterEach(async () => {
  await act(async () => root.unmount())
  delete window.Stimulus
  delete globalThis.IS_REACT_ACT_ENVIRONMENT
  document.body.innerHTML = ''
})

test('registers both handlers on the same editor and cleans them up on unmount', async () => {
  expect(registerDrop).toHaveBeenCalledTimes(1)
  expect(registerTrigger).toHaveBeenCalledTimes(1)
  expect(registerDrop.mock.calls[0][0]).toBe(registerTrigger.mock.calls[0][0])
  await act(async () => root.unmount())
  expect(cleanupDrop).toHaveBeenCalledTimes(1)
  expect(cleanupTrigger).toHaveBeenCalledTimes(1)
})

test.each(['modal', 'stimulus', 'controller'])('declines the picker when %s is missing', missing => {
  if (missing !== 'modal') document.body.insertAdjacentHTML('beforeend', '<div id="link-creative-modal"></div>')
  if (missing !== 'stimulus') window.Stimulus = { getControllerForElementAndIdentifier: jest.fn(() => null) }
  expect(registerTrigger.mock.calls[0][1]({})).toBe(false)
})

test('opens the creative picker with callbacks and creation enabled', () => {
  document.body.insertAdjacentHTML('beforeend', '<div id="link-creative-modal"></div>')
  const controller = { open: jest.fn() }
  window.Stimulus = { getControllerForElementAndIdentifier: jest.fn(() => controller) }
  const anchorRect = { top: 10, left: 20 }
  const onSelect = jest.fn()
  const onClose = jest.fn()
  expect(registerTrigger.mock.calls[0][1]({ anchorRect, onSelect, onClose })).toBe(true)
  expect(window.Stimulus.getControllerForElementAndIdentifier).toHaveBeenCalledWith(
    document.getElementById('link-creative-modal'), 'link-creative'
  )
  expect(controller.open).toHaveBeenCalledWith(anchorRect, onSelect, onClose, { allowCreate: true })
})
