import { $createParagraphNode, $isDecoratorNode, RootNode } from "lexical"

// A top-level DecoratorNode (image / video / attachment) renders as
// non-editable content. When one is the last child of the root there is no
// text position after it, so the caret can't land below it and the whole
// document becomes uneditable — the reported "an image steals focus / can't
// edit" bug, worst when the image is the only block. Guarantee the root always
// ends in a paragraph so there is always an editable landing spot after a
// trailing decorator.
//
// Must run inside an editor.update()/transform.
export function ensureTrailingParagraph(root) {
  const last = root.getLastChild()
  if (last !== null && $isDecoratorNode(last)) {
    last.insertAfter($createParagraphNode())
    return true
  }
  return false
}

// Keep the guarantee while editing too: deleting the text below an image, or
// pasting an image as the last block, would otherwise re-trap the caret.
// Appending leaves the root dirty, so the transform re-runs once more and then
// no-ops (last child is now the paragraph) — it terminates.
export function registerTrailingParagraph(editor) {
  return editor.registerNodeTransform(RootNode, (root) => {
    ensureTrailingParagraph(root)
  })
}
