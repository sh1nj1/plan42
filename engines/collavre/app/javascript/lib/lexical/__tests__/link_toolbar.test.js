/**
 * @jest-environment jsdom
 */

import {
  $createParagraphNode,
  $createTextNode,
  $getRoot,
  createEditor,
} from 'lexical'
import { $createLinkNode, LinkNode } from '@lexical/link'
import {
  $createCreativeLinkNode,
  $isCreativeLinkNode,
  CreativeLinkNode,
} from '../creative_link_node'
import { $createToolbarLinkNode, $findLinkNode } from '../link_toolbar'

function createTestEditor() {
  return createEditor({
    namespace: 'link-toolbar-test',
    nodes: [LinkNode, CreativeLinkNode],
    onError(error) {
      throw error
    },
  })
}

describe('link toolbar helpers', () => {
  test('finds regular and Creative links from their text children', () => {
    const editor = createTestEditor()

    editor.update(() => {
      const paragraph = $createParagraphNode()
      const regularText = $createTextNode('External')
      const creativeText = $createTextNode('Creative')
      const regularLink = $createLinkNode('https://example.com').append(regularText)
      const creativeLink = $createCreativeLinkNode('/creatives/42', 42).append(creativeText)
      paragraph.append(regularLink, creativeLink)
      $getRoot().append(paragraph)

      expect($findLinkNode([regularText])).toBe(regularLink)
      expect($findLinkNode([creativeText])).toBe(creativeLink)
      expect($findLinkNode([creativeLink])).toBe(creativeLink)
      expect($findLinkNode([paragraph])).toBeNull()
    }, { discrete: true })
  })

  test('preserves Creative identity for canonical URLs and converts external URLs', () => {
    const editor = createTestEditor()

    editor.update(() => {
      const creativeLink = $createToolbarLinkNode('/creatives/73')
      const regularLink = $createToolbarLinkNode('https://example.com')

      expect($isCreativeLinkNode(creativeLink)).toBe(true)
      expect(creativeLink.getCreativeId()).toBe(73)
      expect($isCreativeLinkNode(regularLink)).toBe(false)
      expect(regularLink.getType()).toBe('link')
    }, { discrete: true })
  })
})
