import {
  $isRangeSelection,
  $isTextNode,
  $isRootOrShadowRoot
} from "lexical"

// True when a collapsed selection sits at the very start of the whole document
// (offset 0 of the first leaf, with no previous siblings up the tree).
//
// NOTE: checking `$getCharacterOffsets() === [0, 0]` is NOT enough — that only
// reports the offset within the current node, so the start of the *second*
// paragraph (e.g. right after pressing Enter) also reads as [0, 0]. We must walk
// up the tree confirming there is no earlier content, mirroring
// isSelectionAtDocumentEnd.
export function isSelectionAtDocumentStart(selection) {
  if (!$isRangeSelection(selection) || !selection.isCollapsed()) return false

  const anchor = selection.anchor
  let node = anchor.getNode()
  if (!node) return false

  if (anchor.offset !== 0) return false

  while (node && !$isRootOrShadowRoot(node)) {
    if (node.getPreviousSibling()) return false
    node = node.getParent()
  }

  return !!node && $isRootOrShadowRoot(node)
}

// True when a collapsed selection sits at the very end of the whole document
// (end of the last leaf, with no following siblings up the tree).
export function isSelectionAtDocumentEnd(selection) {
  if (!$isRangeSelection(selection) || !selection.isCollapsed()) return false

  const focus = selection.focus
  let node = focus.getNode()
  if (!node) return false

  const offset = focus.offset
  if ($isTextNode(node)) {
    if (offset !== node.getTextContentSize()) return false
  } else if (typeof node.getChildrenSize === "function") {
    if (offset !== node.getChildrenSize()) return false
  } else {
    // Fallback for nodes without children size (e.g., line breaks)
    const textSize = node.getTextContentSize?.() ?? 0
    if (offset !== textSize) return false
  }

  while (node && !$isRootOrShadowRoot(node)) {
    if (node.getNextSibling()) return false
    node = node.getParent()
  }

  return !!node && $isRootOrShadowRoot(node)
}
