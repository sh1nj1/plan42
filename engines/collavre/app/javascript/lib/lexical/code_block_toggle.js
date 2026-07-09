import {
  $createParagraphNode,
  $createTextNode,
  $getSelection,
  $isRangeSelection
} from "lexical"
import { $createCodeNode, $isCodeNode } from "@lexical/code"

/**
 * Toggle the current selection between a code block and normal paragraphs.
 *
 * Must be called inside an editor.update() callback.
 *
 * Selecting several blocks and hitting the code-block button merges ALL of them
 * into a single code block (one line per source block), instead of only the
 * anchor block — the old single-node behaviour dropped every line but the last.
 *
 * When every selected top-level block is already a code block the toggle runs in
 * reverse: each code block is expanded back into one paragraph per line.
 * Any mix of block types (headings, quotes, lists, paragraphs) is absorbed as
 * plain text so the button always has a predictable effect on a range.
 */
export function $toggleCodeBlockForSelection() {
  const selection = $getSelection()
  if (!$isRangeSelection(selection)) return

  const topLevels = $selectedTopLevelBlocks(selection)
  if (topLevels.length === 0) return

  // All selected blocks are code → toggle OFF (expand each back to paragraphs).
  if (topLevels.every($isCodeNode)) {
    let lastParagraph = null
    topLevels.forEach((codeNode) => {
      lastParagraph = $expandCodeNodeToParagraphs(codeNode)
    })
    // The code nodes the selection referenced are gone; move the caret to the
    // end of the expanded text so Lexical keeps a valid selection.
    if (lastParagraph) lastParagraph.selectEnd()
    return
  }

  // Otherwise → merge every selected block's text into a single code block.
  const content = topLevels.map((node) => node.getTextContent()).join("\n")
  const codeNode = $createCodeNode()
  codeNode.append($createTextNode(content))
  topLevels[0].replace(codeNode)
  for (let index = 1; index < topLevels.length; index += 1) {
    topLevels[index].remove()
  }
  codeNode.selectEnd()
}

// Distinct top-level blocks the selection touches, in document order. getNodes()
// returns the range's nodes in document order; each maps to its owning top-level
// element. Falls back to the anchor's block for a collapsed selection.
function $selectedTopLevelBlocks(selection) {
  const seen = new Set()
  const blocks = []
  selection.getNodes().forEach((node) => {
    const topLevel = node.getTopLevelElement()
    if (!topLevel || seen.has(topLevel.getKey())) return
    seen.add(topLevel.getKey())
    blocks.push(topLevel)
  })
  if (blocks.length === 0) {
    const anchorTop = selection.anchor.getNode().getTopLevelElement()
    if (anchorTop) blocks.push(anchorTop)
  }
  return blocks
}

// Replace a code block with one paragraph per line, preserving order. Returns
// the last paragraph so the caller can restore a valid selection (the code
// node the selection pointed at is gone once we replace it).
function $expandCodeNodeToParagraphs(codeNode) {
  const lines = codeNode.getTextContent().split("\n")
  const firstParagraph = $createParagraphNode()
  firstParagraph.append($createTextNode(lines[0] || ""))
  codeNode.replace(firstParagraph)
  let previous = firstParagraph
  for (let index = 1; index < lines.length; index += 1) {
    const paragraph = $createParagraphNode()
    paragraph.append($createTextNode(lines[index]))
    previous.insertAfter(paragraph)
    previous = paragraph
  }
  return previous
}
