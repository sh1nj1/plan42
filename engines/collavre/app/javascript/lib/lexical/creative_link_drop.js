import { $createRangeSelection, $createTextNode, $getRoot, $getSelection, $isRangeSelection, $setSelection } from 'lexical'
import { $isCodeNode } from '@lexical/code'
import { $findMatchingParent } from '@lexical/utils'
import { createDragDropRegistry } from '../dnd/registry'
import { previewDrop } from '../dnd/preview'
import { getCreativeLabelFromDom } from '../dnd/creative_label'
import { $createCreativeLinkNode } from './creative_link_node'

function selectDropPosition(root, event) {
  const doc = root.ownerDocument
  let range = doc.caretRangeFromPoint?.(event.clientX, event.clientY)
  if (!range && doc.caretPositionFromPoint) {
    const caret = doc.caretPositionFromPoint(event.clientX, event.clientY)
    if (caret) {
      range = doc.createRange()
      range.setStart(caret.offsetNode, caret.offset)
      range.collapse(true)
    }
  }
  if (range && root.contains(range.startContainer)) {
    const selection = $createRangeSelection()
    selection.applyDOMRange(range)
    $setSelection(selection)
  }
  let selection = $getSelection()
  if (!$isRangeSelection(selection)) selection = $getRoot().selectEnd()
  // A drop inserts at the caret without deleting an existing text selection.
  selection.focus.set(selection.anchor.key, selection.anchor.offset, selection.anchor.type)
  return selection
}

export function registerCreativeLinkDrop(editor) {
  let registry = null
  const unregisterRoot = editor.registerRootListener((root) => {
    registry?.destroy()
    registry = null
    if (!root) return
    registry = createDragDropRegistry({ root, touch: false })
    registry.registerDropZone({
      selector: '[contenteditable="true"]',
      accepts: (kind) => kind === 'creative' && editor.isEditable(),
      preview: previewDrop,
      dropEffect: 'copy',
      onDrop: ({ ids, event }) => {
        editor.update(() => {
          const selection = selectDropPosition(root, event)
          if ($findMatchingParent(selection.anchor.getNode(), $isCodeNode)) {
            selection.insertText(ids.map(id => `[${getCreativeLabelFromDom(id) || String(id)}](/creatives/${id}) `).join(''))
            return
          }
          const nodes = ids.flatMap((id) => {
            const link = $createCreativeLinkNode(`/creatives/${id}`, id)
            link.append($createTextNode(getCreativeLabelFromDom(id) || String(id)))
            return [link, $createTextNode(' ')]
          })
          selection.insertNodes(nodes)
          nodes[nodes.length - 1].selectEnd()
        }, { discrete: true })
        editor.focus()
      }
    })
  })
  return () => {
    unregisterRoot()
    registry?.destroy()
  }
}
