import {
  $createParagraphNode,
  $createTextNode,
  $getSelection,
  $isDecoratorNode,
  $isRangeSelection
} from "lexical"
import { $createCodeNode, $isCodeNode } from "@lexical/code"
import { $isTableNode } from "@lexical/table"

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

  // Otherwise → merge every selected TEXT block into a single code block.
  // Tables and media (image/video/attachment DecoratorNodes) are structural:
  // their text content is empty or a flattening of tabular data, so absorbing
  // them would silently destroy the table/media. Leave those blocks in place
  // and only merge the real text blocks (matches the old paragraph-only guard,
  // widened to headings/quotes/lists but not to structural containers).
  const mergeable = topLevels.filter($isMergeableTextBlock)
  if (mergeable.length === 0) return
  const content = mergeable.map((node) => node.getTextContent()).join("\n")
  const codeNode = $createCodeNode()
  codeNode.append($createTextNode(content))
  mergeable[0].replace(codeNode)
  for (let index = 1; index < mergeable.length; index += 1) {
    mergeable[index].remove()
  }
  codeNode.selectEnd()
}

// A block can be folded into a code block only if its text content faithfully
// represents it. Tables (tabular structure) and decorator media (no text) do
// not, so they are excluded from the merge to avoid destroying content.
function $isMergeableTextBlock(node) {
  return !$isTableNode(node) && !$isDecoratorNode(node)
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
