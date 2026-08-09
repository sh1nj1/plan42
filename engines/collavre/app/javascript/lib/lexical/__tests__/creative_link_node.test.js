/**
 * @jest-environment jsdom
 */

import {
  $createParagraphNode,
  $createTextNode,
  $getRoot,
  createEditor,
} from 'lexical'
import { LinkNode } from '@lexical/link'
import { $generateHtmlFromNodes, $generateNodesFromDOM } from '@lexical/html'
import {
  $createCreativeLinkNode,
  $isCreativeLinkNode,
  CreativeLinkNode,
  creativeIdFromUrl,
} from '../creative_link_node'
import { lexicalToMarkdown } from '../markdown_serialize'

function createTestEditor() {
  return createEditor({
    namespace: 'creative-link-test',
    nodes: [LinkNode, CreativeLinkNode],
    onError(error) {
      throw error
    },
  })
}

describe('CreativeLinkNode', () => {
  test('extracts creative ids only from canonical internal paths', () => {
    expect(creativeIdFromUrl('/creatives/42')).toBe(42)
    expect(creativeIdFromUrl('/creatives/42?topic_id=3')).toBe(42)
    expect(creativeIdFromUrl('/creatives/42#comments')).toBe(42)
    expect(creativeIdFromUrl('/creatives/42/slide_view')).toBeNull()
    expect(creativeIdFromUrl('/creatives/42/topics')).toBeNull()
    expect(creativeIdFromUrl('https://example.com/creatives/42')).toBeNull()
    expect(creativeIdFromUrl('/creatives/not-a-number')).toBeNull()
  })

  test('exports data-creative-id while keeping canonical Markdown', () => {
    const editor = createTestEditor()
    editor.update(() => {
      const paragraph = $createParagraphNode()
      const link = $createCreativeLinkNode('/creatives/42', 42)
      link.append($createTextNode('Internal page'))
      paragraph.append(link)
      $getRoot().append(paragraph)
    }, { discrete: true })

    let html = ''
    editor.getEditorState().read(() => {
      html = $generateHtmlFromNodes(editor)
    })

    expect(html).toContain('data-creative-id="42"')
    expect(lexicalToMarkdown(editor)).toBe('[Internal page](/creatives/42)')
  })

  test('reconstructs the dedicated node from a canonical internal href', () => {
    const editor = createTestEditor()
    let imported = null

    editor.update(() => {
      const doc = new DOMParser().parseFromString(
        '<p><a href="/creatives/77">Existing</a></p>',
        'text/html',
      )
      const nodes = $generateNodesFromDOM(editor, doc.body)
      nodes.forEach((node) => $getRoot().append(node))
      imported = $getRoot().getFirstChild().getFirstChild()
    }, { discrete: true })

    let importedType = null
    let importedCreativeId = null
    editor.getEditorState().read(() => {
      importedType = imported.getType()
      importedCreativeId = imported.getCreativeId()
    })
    expect(importedType).toBe('creative-link')
    expect(importedCreativeId).toBe(77)
  })

  test('imports serialized nodes and preserves link attributes when cloned', () => {
    const editor = createTestEditor()
    let imported = null
    let cloned = null

    editor.update(() => {
      imported = CreativeLinkNode.importJSON({
        type: 'creative-link',
        version: 1,
        url: '/creatives/51',
        creativeId: 51,
        rel: 'nofollow',
        target: '_blank',
        title: 'Imported page',
      })
      imported.append($createTextNode('Imported'))
      const paragraph = $createParagraphNode()
      paragraph.append(imported)
      $getRoot().append(paragraph)
      cloned = CreativeLinkNode.clone(imported)
    }, { discrete: true })

    editor.getEditorState().read(() => {
      expect(imported.exportJSON()).toMatchObject({
        type: 'creative-link',
        creativeId: 51,
        url: '/creatives/51',
        rel: 'nofollow',
        target: '_blank',
        title: 'Imported page',
      })
      expect($isCreativeLinkNode(imported)).toBe(true)
    })
    expect(cloned.__url).toBe('/creatives/51')
    expect(cloned.__creativeId).toBe(51)
    expect(cloned.__rel).toBe('nofollow')
    expect($isCreativeLinkNode({})).toBe(false)
  })

  test('updates and removes the DOM creative id with the node state', () => {
    const editor = createTestEditor()

    editor.update(() => {
      const paragraph = $createParagraphNode()
      const linked = $createCreativeLinkNode('/creatives/61', 61)
      const unlinked = $createCreativeLinkNode('/other', null)
      paragraph.append(linked, unlinked)
      $getRoot().append(paragraph)

      const element = document.createElement('a')
      linked.updateDOM(linked, element, {})
      expect(element.dataset.creativeId).toBe('61')

      unlinked.updateDOM(linked, element, {})
      expect(element.hasAttribute('data-creative-id')).toBe(false)
    }, { discrete: true })
  })

  test('imports data-creative-id without an href and keeps link attributes', () => {
    const editor = createTestEditor()
    let imported = null

    editor.update(() => {
      const doc = new DOMParser().parseFromString(
        '<p><a data-creative-id="88" rel="nofollow" target="_blank" title="Page">Existing</a></p>',
        'text/html',
      )
      const nodes = $generateNodesFromDOM(editor, doc.body)
      nodes.forEach((node) => $getRoot().append(node))
      imported = $getRoot().getFirstChild().getFirstChild()
    }, { discrete: true })

    editor.getEditorState().read(() => {
      expect(imported.getURL()).toBe('/creatives/88')
      expect(imported.getCreativeId()).toBe(88)
      expect(imported.getRel()).toBe('nofollow')
      expect(imported.getTarget()).toBe('_blank')
      expect(imported.getTitle()).toBe('Page')
    })
  })
})
