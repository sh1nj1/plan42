import {
  $createParagraphNode,
  $getSelection,
  $isRangeSelection,
  COMMAND_PRIORITY_LOW,
  INDENT_CONTENT_COMMAND,
  KEY_TAB_COMMAND,
  OUTDENT_CONTENT_COMMAND
} from "lexical"
import { $createListNode, $isListItemNode, $isListNode } from "@lexical/list"

/**
 * Tab / Shift+Tab indentation scoped to list items.
 *
 * Inside a list, Tab nests the current item (INDENT_CONTENT_COMMAND).
 * Shift+Tab un-nests it (OUTDENT_CONTENT_COMMAND) when the item is nested;
 * @lexical/list turns those indent changes into real nested <ul>/<ol> structure.
 *
 * At the OUTERMOST level OUTDENT_CONTENT_COMMAND is a no-op (there is no shallower
 * indent to drop to), so Shift+Tab on a top-level item would do nothing. Other
 * editors instead remove the list formatting for that item — the item leaves the
 * list and becomes a normal paragraph. We replicate that here so Shift+Tab always
 * has a visible, expected effect.
 *
 * Outside a list the command is ignored (returns false) so Tab keeps its default
 * behaviour (moving focus out of the editor) and plain paragraphs never gain an
 * indent the Markdown-canonical store can't represent cleanly.
 *
 * Returns the editor.registerCommand teardown so callers can clean up.
 */
export function registerListTabIndentation(editor) {
  return editor.registerCommand(
    KEY_TAB_COMMAND,
    (event) => {
      const selection = $getSelection()
      if (!$isRangeSelection(selection)) return false
      const listItem = $findListItemAncestor(selection)
      if (!listItem) return false

      event.preventDefault()

      if (event.shiftKey) {
        // Top-level item: drop out of the list entirely (other editors' behaviour),
        // because OUTDENT has nothing shallower to move to. Nested item: un-nest one
        // level via OUTDENT, which @lexical/list collapses back into flat structure.
        if ($isTopLevelListItem(listItem)) {
          $convertListItemToParagraph(listItem)
          return true
        }
        return editor.dispatchCommand(OUTDENT_CONTENT_COMMAND, undefined)
      }

      return editor.dispatchCommand(INDENT_CONTENT_COMMAND, undefined)
    },
    COMMAND_PRIORITY_LOW
  )
}

// A list item that exists only to hold a nested list (its first/only child is a
// ListNode). @lexical/list uses this wrapper to represent indentation.
function $isNestedListItemWrapper(node) {
  return $isListItemNode(node) && $isListNode(node.getFirstChild())
}

function $findListItemAncestor(selection) {
  const anchorNode = selection.anchor.getNode()
  if ($isListItemNode(anchorNode)) return anchorNode
  return anchorNode.getParents().find($isListItemNode) || null
}

// A list item is "top level" when its parent list is not nested inside another
// list item. This holds both at the document root and inside a blockquote (where
// the list's parent is the QuoteNode, not the root) — in both cases OUTDENT has
// nothing shallower to drop to, so the item should leave the list instead.
function $isTopLevelListItem(listItem) {
  const parentList = listItem.getParent()
  if (!$isListNode(parentList)) return false
  return !$isListItemNode(parentList.getParent())
}

// Remove a single top-level list item from its list, turning it into a paragraph
// in the same position. Items before it stay in the original list; items after it
// move into a fresh trailing list so the surrounding list is split, not flattened.
function $convertListItemToParagraph(listItem) {
  const parentList = listItem.getParent()
  if (!$isListNode(parentList)) return

  const following = listItem.getNextSiblings()
  // An item can hold both inline content (text) and a nested child list. Only the
  // inline content belongs in the paragraph — a nested ListNode inside a paragraph
  // is invalid block structure, so it is promoted to a sibling list block instead.
  const children = listItem.getChildren()
  const nestedLists = children.filter($isListNode)
  const inlineChildren = children.filter((child) => !$isListNode(child))
  const paragraph = $createParagraphNode()

  parentList.insertAfter(paragraph)

  // Keep block order: paragraph, then any promoted nested lists, then the split-off
  // trailing items, by chaining insertAfter off the previously inserted block.
  let anchor = paragraph
  nestedLists.forEach((nestedList) => {
    anchor.insertAfter(nestedList)
    anchor = nestedList
  })

  if (following.length > 0) {
    const listType = parentList.getListType()
    // @lexical/list stores a nested child list as a *wrapper* list item (its only
    // child is a ListNode) placed right after the parent item. The leading run of
    // such wrappers are the removed item's own children: promote each wrapper's
    // inner ListNode up one level as its own block, then drop the emptied wrapper.
    // Moving the whole ListNode (not just its items) preserves the child list's own
    // marker type — a bullet child of a numbered parent must stay a bullet list, not
    // get renumbered. Promoting items rather than the wrapper also empties parentList
    // so the cleanup below can remove it, avoiding an orphan <li><ul>. Once a real
    // item appears the run ends; later wrappers belong to it and must stay nested.
    let promotingChildren = true
    const trailingItems = []
    following.forEach((sibling) => {
      if (promotingChildren && $isNestedListItemWrapper(sibling)) {
        const childList = sibling.getFirstChild()
        anchor.insertAfter(childList)
        anchor = childList
        sibling.remove()
      } else {
        promotingChildren = false
        trailingItems.push(sibling)
      }
    })
    if (trailingItems.length > 0) {
      // For ordered lists, continue numbering from where the converted item was
      // instead of restarting at 1 (e.g. "1. a / 2. b / 3. c" → outdent b → c stays 3).
      const trailingStart =
        listType === "number" ? listItem.getValue() + 1 : undefined
      const trailingList = $createListNode(listType, trailingStart)
      trailingItems.forEach((sibling) => trailingList.append(sibling))
      anchor.insertAfter(trailingList)
    }
  }

  if (inlineChildren.length > 0) {
    // Moving the existing nodes (not cloning) keeps any caret pointing into them
    // valid, so the cursor stays where the user was typing.
    inlineChildren.forEach((child) => paragraph.append(child))
  } else {
    paragraph.select()
  }

  listItem.remove()

  if (parentList.getChildrenSize() === 0) {
    parentList.remove()
  }
}
