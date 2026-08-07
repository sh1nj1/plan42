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
})
