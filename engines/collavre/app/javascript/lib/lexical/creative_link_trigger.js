import {
  $createRangeSelection,
  $createTextNode,
  $getNodeByKey,
  $getSelection,
  $isRangeSelection,
  $isTextNode,
  $setSelection,
} from "lexical"
import { $createCreativeLinkNode } from "./creative_link_node"

function currentTrigger() {
  const selection = $getSelection()
  if (!$isRangeSelection(selection) || !selection.isCollapsed()) return null

  const node = selection.anchor.getNode()
  if (!$isTextNode(node)) return null
  if (["code", "link", "creative-link"].includes(node.getParent()?.getType())) return null

  const offset = selection.anchor.offset
  if (node.getTextContent().slice(0, offset).slice(-2) !== "[[") return null

  return { key: node.getKey(), start: offset - 2, end: offset }
}

function selectionRect(editor) {
  const domSelection = window.getSelection?.()
  if (domSelection?.rangeCount) {
    const rect = domSelection.getRangeAt(0).getBoundingClientRect?.()
    if (rect) return rect
  }
  return editor.getRootElement()?.getBoundingClientRect?.() || null
}

export function insertCreativeLinkAtTrigger(editor, trigger, item) {
  if (!trigger || !item?.id) return false
  let inserted = false

  editor.update(() => {
    const node = $getNodeByKey(trigger.key)
    if (!$isTextNode(node)) return
    if (node.getTextContent().slice(trigger.start, trigger.end) !== "[[") return

    const selection = $createRangeSelection()
    selection.anchor.set(trigger.key, trigger.start, "text")
    selection.focus.set(trigger.key, trigger.end, "text")
    $setSelection(selection)

    const link = $createCreativeLinkNode(`/creatives/${item.id}`, item.id)
    link.append($createTextNode(item.label || String(item.id)))
    const trailingSpace = $createTextNode(" ")
    selection.insertNodes([link, trailingSpace])
    trailingSpace.selectEnd()
    inserted = true
  }, { discrete: true })

  if (inserted) editor.focus()
  return inserted
}

export function registerCreativeLinkTrigger(editor, openPicker) {
  let pickerOpen = false
  let dismissedTrigger = null

  return editor.registerUpdateListener(({ editorState }) => {
    if (pickerOpen) return

    let trigger = null
    editorState.read(() => {
      trigger = currentTrigger()
    })
    if (!trigger) {
      dismissedTrigger = null
      return
    }
    if (
      dismissedTrigger &&
      dismissedTrigger.key === trigger.key &&
      dismissedTrigger.start === trigger.start &&
      dismissedTrigger.end === trigger.end
    ) return

    pickerOpen = true
    const opened = openPicker({
      anchorRect: selectionRect(editor),
      onSelect: (item) => {
        insertCreativeLinkAtTrigger(editor, trigger, item)
        pickerOpen = false
      },
      onClose: () => {
        dismissedTrigger = trigger
        pickerOpen = false
        editor.focus()
      }
    })
    if (opened === false) pickerOpen = false
  })
}
