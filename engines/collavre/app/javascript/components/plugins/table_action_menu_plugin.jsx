import { useCallback, useEffect, useRef, useState } from "react"
import { createPortal } from "react-dom"
import { useLexicalComposerContext } from "@lexical/react/LexicalComposerContext"
import { useLexicalEditable } from "@lexical/react/useLexicalEditable"
import {
  $deleteTableColumnAtSelection,
  $deleteTableRowAtSelection,
  $getTableCellNodeFromLexicalNode,
  $getTableNodeFromLexicalNodeOrThrow,
  $insertTableColumnAtSelection,
  $insertTableRowAtSelection,
  $isTableCellNode,
  $isTableSelection,
  getTableElement,
  getTableObserverFromTableElement
} from "@lexical/table"
import { mergeRegister } from "@lexical/utils"
import {
  $getSelection,
  $isRangeSelection,
  $setSelection,
  COMMAND_PRIORITY_CRITICAL,
  getDOMSelection,
  isDOMNode,
  SELECTION_CHANGE_COMMAND
} from "lexical"

// Per-cell action menu: a chevron button appears at the active cell's top-right
// corner; clicking it opens a dropdown to insert/delete rows and columns or
// delete the table. Trimmed from the Lexical playground's TableActionMenuPlugin
// to only the actions that survive GFM markdown round-trip — merge, cell color,
// striping, vertical-align, freeze and header toggles are intentionally dropped
// (they cannot be represented in a pipe table, our canonical storage form).

function computeSelectionCount(selection) {
  const shape = selection.getShape()
  return {
    columns: shape.toX - shape.fromX + 1,
    rows: shape.toY - shape.fromY + 1
  }
}

function TableActionMenu({ onClose, tableCellNode, setIsMenuOpen, contextRef, anchorElem }) {
  const [editor] = useLexicalComposerContext()
  const dropDownRef = useRef(null)
  const [selectionCounts, updateSelectionCounts] = useState({ columns: 1, rows: 1 })

  useEffect(() => {
    editor.getEditorState().read(() => {
      const selection = $getSelection()
      if ($isTableSelection(selection)) {
        updateSelectionCounts(computeSelectionCount(selection))
      }
    })
  }, [editor])

  // Position the dropdown next to the chevron, in coordinates relative to the
  // anchor (.lexical-editor-inner) the menu is portaled into — NOT viewport
  // coords against document.body. A body-portaled position:fixed menu only
  // resolves to the viewport when no ancestor has a transform/filter/will-change;
  // the desktop app layout establishes such a context (mobile's media-query layout
  // does not), so fixed coords landed the menu off-screen on PC and the off-bounds
  // element forced a reflow that bounced the chevron. Anchoring to the editor's own
  // box — the same proven pattern as the hover "+" buttons — sidesteps all of it.
  useEffect(() => {
    const menuButtonElement = contextRef.current
    const dropDownElement = dropDownRef.current

    if (menuButtonElement != null && dropDownElement != null && anchorElem != null) {
      const anchorRect = anchorElem.getBoundingClientRect()
      const menuButtonRect = menuButtonElement.getBoundingClientRect()
      dropDownElement.style.opacity = "1"
      const dropDownElementRect = dropDownElement.getBoundingClientRect()
      const margin = 5

      // Default: just right of the chevron. Flip left if it would overflow the
      // anchor's right edge or the viewport.
      let left = menuButtonRect.right - anchorRect.left + margin
      if (
        menuButtonRect.right + margin + dropDownElementRect.width > window.innerWidth ||
        left + dropDownElementRect.width > anchorRect.width
      ) {
        left = menuButtonRect.left - anchorRect.left - dropDownElementRect.width - margin
        if (left < margin) left = margin
      }
      dropDownElement.style.left = `${left}px`

      let top = menuButtonRect.top - anchorRect.top
      if (menuButtonRect.top + dropDownElementRect.height > window.innerHeight) {
        top = menuButtonRect.bottom - anchorRect.top - dropDownElementRect.height
        if (top < margin) top = margin
      }
      dropDownElement.style.top = `${top}px`
    }
  }, [contextRef, editor, anchorElem])

  useEffect(() => {
    function handleClickOutside(event) {
      if (
        dropDownRef.current != null &&
        contextRef.current != null &&
        isDOMNode(event.target) &&
        !dropDownRef.current.contains(event.target) &&
        !contextRef.current.contains(event.target)
      ) {
        setIsMenuOpen(false)
      }
    }
    window.addEventListener("click", handleClickOutside)
    return () => window.removeEventListener("click", handleClickOutside)
  }, [setIsMenuOpen, contextRef])

  const clearTableSelection = useCallback(() => {
    editor.update(() => {
      if (tableCellNode.isAttached()) {
        const tableNode = $getTableNodeFromLexicalNodeOrThrow(tableCellNode)
        const tableElement = getTableElement(tableNode, editor.getElementByKey(tableNode.getKey()))
        const tableObserver =
          tableElement && getTableObserverFromTableElement(tableElement)
        if (tableObserver) tableObserver.$clearHighlight()
        tableNode.markDirty()
      }
      $setSelection(null)
    })
  }, [editor, tableCellNode])

  const insertTableRow = useCallback(
    (shouldInsertAfter) => {
      editor.update(() => {
        for (let i = 0; i < selectionCounts.rows; i++) {
          $insertTableRowAtSelection(shouldInsertAfter)
        }
        onClose()
      })
    },
    [editor, onClose, selectionCounts.rows]
  )

  const insertTableColumn = useCallback(
    (shouldInsertAfter) => {
      editor.update(() => {
        for (let i = 0; i < selectionCounts.columns; i++) {
          $insertTableColumnAtSelection(shouldInsertAfter)
        }
        onClose()
      })
    },
    [editor, onClose, selectionCounts.columns]
  )

  const deleteTableRow = useCallback(() => {
    editor.update(() => {
      $deleteTableRowAtSelection()
      onClose()
    })
  }, [editor, onClose])

  const deleteTableColumn = useCallback(() => {
    editor.update(() => {
      $deleteTableColumnAtSelection()
      onClose()
    })
  }, [editor, onClose])

  const deleteTable = useCallback(() => {
    editor.update(() => {
      const tableNode = $getTableNodeFromLexicalNodeOrThrow(tableCellNode)
      tableNode.remove()
      clearTableSelection()
      onClose()
    })
  }, [editor, tableCellNode, clearTableSelection, onClose])

  return createPortal(
    <div
      className="lexical-table-action-menu-dropdown"
      ref={dropDownRef}
      onClick={(e) => e.stopPropagation()}
      // Same focus-steal guard as the chevron: keep the table selection intact
      // so the insert/delete editor.update operates on the right cells.
      onMouseDown={(e) => e.preventDefault()}
    >
      <button type="button" className="lexical-table-action-menu-item" onClick={() => insertTableRow(false)}>
        <span>Insert row above</span>
      </button>
      <button type="button" className="lexical-table-action-menu-item" onClick={() => insertTableRow(true)}>
        <span>Insert row below</span>
      </button>
      <hr />
      <button type="button" className="lexical-table-action-menu-item" onClick={() => insertTableColumn(false)}>
        <span>Insert column left</span>
      </button>
      <button type="button" className="lexical-table-action-menu-item" onClick={() => insertTableColumn(true)}>
        <span>Insert column right</span>
      </button>
      <hr />
      <button type="button" className="lexical-table-action-menu-item" onClick={deleteTableRow}>
        <span>Delete row</span>
      </button>
      <button type="button" className="lexical-table-action-menu-item" onClick={deleteTableColumn}>
        <span>Delete column</span>
      </button>
      <button type="button" className="lexical-table-action-menu-item" onClick={deleteTable}>
        <span>Delete table</span>
      </button>
    </div>,
    anchorElem
  )
}

function TableCellActionMenuContainer({ anchorElem }) {
  const [editor] = useLexicalComposerContext()
  const menuButtonRef = useRef(null)
  const menuRootRef = useRef(null)
  const [isMenuOpen, setIsMenuOpen] = useState(false)
  const [tableCellNode, setTableMenuCellNode] = useState(null)

  // Track the cell under the caret and park the chevron button at its top-right.
  const $moveMenu = useCallback(() => {
    const menu = menuButtonRef.current
    const selection = $getSelection()
    const nativeSelection = getDOMSelection(editor._window)
    const activeElement = document.activeElement

    function disable() {
      if (menu) {
        menu.classList.remove("lexical-table-cell-action-button-container--active")
        menu.classList.add("lexical-table-cell-action-button-container--inactive")
      }
      setTableMenuCellNode(null)
    }

    if (selection == null || menu == null) return disable()

    const rootElement = editor.getRootElement()
    let tableObserver = null
    let tableCellParentNodeDOM = null

    if (
      $isRangeSelection(selection) &&
      rootElement !== null &&
      nativeSelection !== null &&
      rootElement.contains(nativeSelection.anchorNode)
    ) {
      const tableCellNodeFromSelection = $getTableCellNodeFromLexicalNode(
        selection.anchor.getNode()
      )
      if (tableCellNodeFromSelection == null) return disable()

      tableCellParentNodeDOM = editor.getElementByKey(tableCellNodeFromSelection.getKey())
      if (tableCellParentNodeDOM == null || !tableCellNodeFromSelection.isAttached()) {
        return disable()
      }

      const tableNode = $getTableNodeFromLexicalNodeOrThrow(tableCellNodeFromSelection)
      const tableElement = getTableElement(tableNode, editor.getElementByKey(tableNode.getKey()))
      if (tableElement === null) return disable()

      tableObserver = getTableObserverFromTableElement(tableElement)
      setTableMenuCellNode(tableCellNodeFromSelection)
    } else if ($isTableSelection(selection)) {
      const anchorNode = $getTableCellNodeFromLexicalNode(selection.anchor.getNode())
      if (!$isTableCellNode(anchorNode)) return disable()
      const tableNode = $getTableNodeFromLexicalNodeOrThrow(anchorNode)
      const tableElement = getTableElement(tableNode, editor.getElementByKey(tableNode.getKey()))
      if (tableElement === null) return disable()
      tableObserver = getTableObserverFromTableElement(tableElement)
      tableCellParentNodeDOM = editor.getElementByKey(anchorNode.getKey())
      if (tableCellParentNodeDOM === null) return disable()
    } else if (!activeElement) {
      return disable()
    }

    if (tableObserver === null || tableCellParentNodeDOM === null) return disable()

    const enabled = !tableObserver || !tableObserver.isSelecting
    menu.classList.toggle("lexical-table-cell-action-button-container--active", enabled)
    menu.classList.toggle("lexical-table-cell-action-button-container--inactive", !enabled)
    if (enabled) {
      const tableCellRect = tableCellParentNodeDOM.getBoundingClientRect()
      const anchorRect = anchorElem.getBoundingClientRect()
      const top = tableCellRect.top - anchorRect.top
      const left = tableCellRect.right - anchorRect.left
      menu.style.transform = `translate(${left}px, ${top}px)`
    }
  }, [editor, anchorElem])

  useEffect(() => {
    // Re-evaluate the menu position on every selection change, once up front, and
    // once after each pointerUp (table selections settle on pointer release).
    let timeoutId
    const callback = () => {
      timeoutId = undefined
      editor.getEditorState().read($moveMenu)
    }
    const delayedCallback = () => {
      if (timeoutId === undefined) timeoutId = setTimeout(callback, 0)
      return false
    }
    return mergeRegister(
      editor.registerUpdateListener(delayedCallback),
      editor.registerCommand(SELECTION_CHANGE_COMMAND, delayedCallback, COMMAND_PRIORITY_CRITICAL),
      editor.registerRootListener((rootElement, prevRootElement) => {
        if (prevRootElement) prevRootElement.removeEventListener("pointerup", delayedCallback)
        if (rootElement) {
          rootElement.addEventListener("pointerup", delayedCallback)
          delayedCallback()
        }
      }),
      () => clearTimeout(timeoutId)
    )
  })

  // Close the dropdown whenever the active cell changes out from under it.
  const prevTableCellDOM = useRef(tableCellNode)
  useEffect(() => {
    if (prevTableCellDOM.current !== tableCellNode) setIsMenuOpen(false)
    prevTableCellDOM.current = tableCellNode
  }, [prevTableCellDOM, tableCellNode])

  return (
    <div className="lexical-table-cell-action-button-container" ref={menuButtonRef}>
      {tableCellNode != null && (
        <>
          <button
            type="button"
            className="lexical-table-cell-action-button"
            aria-label="Table row and column actions"
            // Keep the editor's selection put. A bare button click fires
            // mousedown first, which on desktop steals focus from the
            // contenteditable and collapses the native selection out of the
            // editor root. That makes the very next $moveMenu (fired by the
            // resulting selectionchange) find no cell under the selection, call
            // disable() → null the cell → close the menu and shift the chevron
            // (the "flash then vanish" + bounce). Touch devices don't do the
            // mousedown focus-steal, which is why it only broke on PC.
            // preventDefault on mousedown blocks the focus-steal; onClick still
            // fires so the toggle works.
            onMouseDown={(e) => e.preventDefault()}
            onClick={(e) => {
              e.stopPropagation()
              setIsMenuOpen(!isMenuOpen)
            }}
            ref={menuRootRef}
          >
            <span aria-hidden="true">▾</span>
          </button>
          {isMenuOpen && (
            <TableActionMenu
              contextRef={menuRootRef}
              setIsMenuOpen={setIsMenuOpen}
              onClose={() => setIsMenuOpen(false)}
              tableCellNode={tableCellNode}
              anchorElem={anchorElem}
            />
          )}
        </>
      )}
    </div>
  )
}

export default function TableActionMenuPlugin({ anchorElem = document.body } = {}) {
  const isEditable = useLexicalEditable()
  return createPortal(
    isEditable ? <TableCellActionMenuContainer anchorElem={anchorElem} /> : null,
    anchorElem
  )
}
