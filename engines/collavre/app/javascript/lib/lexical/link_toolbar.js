import { $createLinkNode, $isLinkNode } from '@lexical/link'
import {
  $createCreativeLinkNode,
  creativeIdFromUrl,
} from './creative_link_node'

export function $findLinkNode(nodes) {
  for (const node of nodes) {
    if ($isLinkNode(node)) return node

    const parent = node.getParent()
    if ($isLinkNode(parent)) return parent
  }

  return null
}

export function $createToolbarLinkNode(url) {
  const creativeId = creativeIdFromUrl(url)
  return creativeId
    ? $createCreativeLinkNode(url, creativeId)
    : $createLinkNode(url)
}
