import {
  $createParagraphNode,
  $createTextNode,
  $getSelection,
  $isDecoratorNode,
  $isRangeSelection
} from "lexical"
import { $createCodeNode, $isCodeNode } from "@lexical/code"
import { $isTableNode } from "@lexical/table"
import { $isListNode } from "@lexical/list"

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
 * Text blocks (headings, quotes, paragraphs) are absorbed as plain text; tables,
 * media, and lists are structural and left in place (see $isMergeableTextBlock).
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

  // Otherwise → fold the selected TEXT blocks into code blocks. Tables and media
  // (image/video/attachment DecoratorNodes) are structural: their text content is
  // empty or a flattening of tabular data, so absorbing them would silently
  // destroy the table/media. They are left in place, which SPLITS the selection:
  // merging text from both sides of a structural block into one code block would
  // pull later content across the block and corrupt document order. So each
  // contiguous run of text blocks becomes its own code block, structural blocks
  // untouched in between (matches the old paragraph-only guard, widened to
  // headings/quotes/lists but not across structural containers).
  let run = []
  let lastCode = null
  const flushRun = () => {
    if (run.length === 0) return
    const content = run.map((node) => node.getTextContent()).join("\n")
    const codeNode = $createCodeNode()
    codeNode.append($createTextNode(content))
    run[0].replace(codeNode)
    for (let index = 1; index < run.length; index += 1) run[index].remove()
    lastCode = codeNode
    run = []
  }
  topLevels.forEach((node) => {
    if ($isMergeableTextBlock(node)) run.push(node)
    else flushRun()
  })
  flushRun()
  if (lastCode) lastCode.selectEnd()
}

// A block can be folded into a code block only if its text content faithfully
// represents it. Tables (tabular structure) and decorator media (no text) do
// not, so they are excluded from the merge to avoid destroying content.
function $isMergeableTextBlock(node) {
  if ($isTableNode(node) || $isDecoratorNode(node)) return false
  // A ListNode is the top-level element for every bullet, so selecting text in
  // ONE bullet top-levels to the whole list. Merging it would flatten every
  // sibling bullet (via getTextContent()) and replace the entire list — losing
  // unselected bullets. Item-granular folding (split the list, keep the rest) is
  // out of scope here, so lists are treated as structural and left in place;
  // convert a list to code via a ``` fence instead.
  if ($isListNode(node)) return false
  // TableCellNode is a shadow root, so getTopLevelElement() on cell content
  // returns the cell's own paragraph — a plain block that slips past the
  // $isTableNode check above. Merging that cell block with document-root blocks
  // moves content across the table boundary (relocating outside text into a
  // cell, or replacing the cell body). Never merge table-scoped blocks.
  if (node.getParents().some($isTableNode)) return false
  return true
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
