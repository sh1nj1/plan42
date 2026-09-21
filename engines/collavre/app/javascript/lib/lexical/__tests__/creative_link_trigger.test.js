/**
 * @jest-environment jsdom
 */

import { jest } from '@jest/globals'
import {
  $createParagraphNode,
  $createTextNode,
  $getRoot,
  createEditor,
} from 'lexical'
import { LinkNode } from '@lexical/link'
import { CreativeLinkNode } from '../creative_link_node'
import { registerCreativeLinkTrigger } from '../creative_link_trigger'
import { lexicalToMarkdown } from '../markdown_serialize'

const flush = () => new Promise((resolve) => setTimeout(resolve, 0))

function createTestEditor() {
  const editor = createEditor({
    namespace: 'creative-link-trigger-test',
    nodes: [LinkNode, CreativeLinkNode],
    onError(error) {
      throw error
    },
  })
  const root = document.createElement('div')
  root.contentEditable = 'true'
  document.body.appendChild(root)
  editor.setRootElement(root)
  return editor
}

describe('creative link [[ trigger', () => {
  afterEach(() => {
    document.body.innerHTML = ''
  })

  test('opens once and replaces the trigger with a canonical creative link', async () => {
    const editor = createTestEditor()
    const openPicker = jest.fn(() => true)
    const unregister = registerCreativeLinkTrigger(editor, openPicker)

    editor.update(() => {
      const paragraph = $createParagraphNode()
      const text = $createTextNode('Before [[')
      paragraph.append(text)
      $getRoot().append(paragraph)
      text.selectEnd()
    }, { discrete: true })
    await flush()

    expect(openPicker).toHaveBeenCalledTimes(1)
    openPicker.mock.calls[0][0].onSelect({ id: 99, label: 'Target page' })

    expect(lexicalToMarkdown(editor)).toBe('Before [Target page](/creatives/99)')
    expect(openPicker).toHaveBeenCalledTimes(1)
    unregister()
  })

  test('keeps the trigger when the picker cannot open', async () => {
    const editor = createTestEditor()
    const openPicker = jest.fn(() => false)
    const unregister = registerCreativeLinkTrigger(editor, openPicker)

    editor.update(() => {
      const paragraph = $createParagraphNode()
      const text = $createTextNode('[[')
      paragraph.append(text)
      $getRoot().append(paragraph)
      text.selectEnd()
    }, { discrete: true })
    await flush()

    expect(openPicker).toHaveBeenCalledTimes(1)
    expect(lexicalToMarkdown(editor)).toBe('[[')
    unregister()
  })

  test('does not immediately reopen a dismissed trigger', async () => {
    const editor = createTestEditor()
    const openPicker = jest.fn(() => true)
    const unregister = registerCreativeLinkTrigger(editor, openPicker)

    let textNode = null
    editor.update(() => {
      const paragraph = $createParagraphNode()
      textNode = $createTextNode('[[')
      paragraph.append(textNode)
      $getRoot().append(paragraph)
      textNode.selectEnd()
    }, { discrete: true })
    await flush()

    openPicker.mock.calls[0][0].onClose()
    editor.update(() => textNode.getLatest().selectEnd(), { discrete: true })
    await flush()

    expect(openPicker).toHaveBeenCalledTimes(1)
    unregister()
  })

  test('clears a dismissed trigger after editing away and opens for a new trigger', async () => {
    const editor = createTestEditor()
    const openPicker = jest.fn(() => true)
    const unregister = registerCreativeLinkTrigger(editor, openPicker)

    let textNode = null
    editor.update(() => {
      const paragraph = $createParagraphNode()
      textNode = $createTextNode('[[')
      paragraph.append(textNode)
      $getRoot().append(paragraph)
      textNode.selectEnd()
    }, { discrete: true })
    await flush()
    openPicker.mock.calls[0][0].onClose()

    editor.update(() => {
      textNode.getLatest().setTextContent('plain')
      textNode.getLatest().selectEnd()
    }, { discrete: true })
    await flush()
    editor.update(() => {
      textNode.getLatest().setTextContent('plain [[')
      textNode.getLatest().selectEnd()
    }, { discrete: true })
    await flush()

    expect(openPicker).toHaveBeenCalledTimes(2)
    unregister()
  })
})
