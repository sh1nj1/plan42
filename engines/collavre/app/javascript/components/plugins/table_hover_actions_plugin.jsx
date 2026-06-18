import { useEffect, useMemo, useRef, useState } from "react"
import { createPortal } from "react-dom"
import { useLexicalComposerContext } from "@lexical/react/LexicalComposerContext"
import { useLexicalEditable } from "@lexical/react/useLexicalEditable"
import {
  $deleteTableColumnAtSelection,
  $deleteTableRowAtSelection,
  $getTableAndElementByKey,
  $getTableColumnIndexFromTableCellNode,
  $getTableRowIndexFromTableCellNode,
  $insertTableColumnAtSelection,
  $insertTableRowAtSelection,
  $isTableCellNode,
  $isTableNode,
  getTableElement,
  TableNode
} from "@lexical/table"
import { $findMatchingParent, mergeRegister } from "@lexical/utils"
import { $getNearestNodeFromDOMNode, isHTMLElement } from "lexical"

// Cell-boundary action buttons, all driven purely by `mousemove` (never by focus
// or selection): hover near a table's bottom edge to append a row, near its right
// edge to append a column, and hover any cell to reveal "×" buttons in the row's
// left gutter / the column's top gutter that delete that row / column.
//
// Delete used to live in a chevron dropdown (TableActionMenuPlugin) that tracked
// the editor selection and portaled a floating menu. On desktop, clicking the
// chevron stole focus from the contenteditable, which collapsed the selection out
// of the editor and made the menu flash-then-close while the chevron bounced — a
// focus/selection/render-timing race that could not be reproduced headless and
// survived four positioning fixes. This mousemove-driven approach has none of that
// machinery (no selection tracking, no $moveMenu, no click-outside, no focus
// dependency), which is exactly why the add "+" buttons always worked on PC and
// mobile alike. Ported/extended from the Lexical playground's TableHoverActions.

const BUTTON_WIDTH_PX = 20
const DELETE_BUTTON_PX = 18

// Build a CSS selector from a theme class name (mirrors the playground helper).
function getThemeSelector(getTheme, name) {
  const className = getTheme()?.[name]
  if (typeof className !== "string") {
    throw new Error(`getThemeSelector: required theme property ${name} not defined`)
  }
  return className
    .split(/\s+/g)
    .map((cls) => `.${cls}`)
    .join()
}

// Trailing-edge debounce with a maxWait ceiling and a cancel() method.
function useDebounce(fn, ms, maxWait) {
  const fnRef = useRef(fn)
  fnRef.current = fn
  return useMemo(() => {
    let timer = null
    let firstCall = 0
    const invoke = (args) => {
      timer = null
      firstCall = 0
      fnRef.current(...args)
    }
    const debounced = (...args) => {
      const now = Date.now()
      if (!timer) firstCall = now
      if (timer) clearTimeout(timer)
      const waitedFor = now - firstCall
      const remainingMax = maxWait != null ? Math.max(0, maxWait - waitedFor) : Infinity
      const delay = Math.min(ms, remainingMax)
      timer = setTimeout(() => invoke(args), delay)
    }
    debounced.cancel = () => {
      if (timer) clearTimeout(timer)
      timer = null
      firstCall = 0
    }
    return debounced
  }, [ms, maxWait])
}

function getMouseInfo(event, getTheme) {
  const target = event.target
  const tableCellClass = getThemeSelector(getTheme, "tableCell")

  if (isHTMLElement(target)) {
    const tableDOMNode = target.closest(`td${tableCellClass}, th${tableCellClass}`)

    const isOutside = !(
      tableDOMNode ||
      target.closest(`button${getThemeSelector(getTheme, "tableAddRows")}`) ||
      target.closest(`button${getThemeSelector(getTheme, "tableAddColumns")}`) ||
      target.closest(`button${getThemeSelector(getTheme, "tableDeleteRows")}`) ||
      target.closest(`button${getThemeSelector(getTheme, "tableDeleteColumns")}`) ||
      target.closest("div.TableCellResizer__resizer")
    )

    return { isOutside, tableDOMNode }
  }
  return { isOutside: true, tableDOMNode: null }
}

function TableHoverActionsContainer({ anchorElem }) {
  const [editor, { getTheme }] = useLexicalComposerContext()
  const isEditable = useLexicalEditable()
  const [isShownRow, setShownRow] = useState(false)
  const [isShownColumn, setShownColumn] = useState(false)
  const [isShownDeleteRow, setShownDeleteRow] = useState(false)
  const [isShownDeleteColumn, setShownDeleteColumn] = useState(false)
  const [shouldListenMouseMove, setShouldListenMouseMove] = useState(false)
  const [position, setPosition] = useState({})
  const [deleteRowPosition, setDeleteRowPosition] = useState({})
  const [deleteColumnPosition, setDeleteColumnPosition] = useState({})
  const tableSetRef = useRef(new Set())
  const tableCellDOMNodeRef = useRef(null)

  const hideAll = () => {
    setShownRow(false)
    setShownColumn(false)
    setShownDeleteRow(false)
    setShownDeleteColumn(false)
  }

  const debouncedOnMouseMove = useDebounce(
    (event) => {
      const { isOutside, tableDOMNode } = getMouseInfo(event, getTheme)

      if (isOutside) {
        hideAll()
        return
      }

      if (!tableDOMNode) return

      tableCellDOMNodeRef.current = tableDOMNode

      let hoveredRowNode = null
      let hoveredColumnNode = null
      let tableDOMElement = null
      let canDeleteRow = false
      let canDeleteColumn = false

      editor.getEditorState().read(
        () => {
          const maybeTableCell = $getNearestNodeFromDOMNode(tableDOMNode)

          if ($isTableCellNode(maybeTableCell)) {
            const table = $findMatchingParent(maybeTableCell, (node) => $isTableNode(node))
            if (!$isTableNode(table)) return

            tableDOMElement = getTableElement(table, editor.getElementByKey(table.getKey()))

            if (tableDOMElement) {
              const rowCount = table.getChildrenSize()
              const colCount = table.getChildAtIndex(0)?.getChildrenSize()

              const rowIndex = $getTableRowIndexFromTableCellNode(maybeTableCell)
              const colIndex = $getTableColumnIndexFromTableCellNode(maybeTableCell)

              if (rowIndex === rowCount - 1) {
                hoveredRowNode = maybeTableCell
              } else if (colIndex === colCount - 1) {
                hoveredColumnNode = maybeTableCell
              }

              // Deleting the only row/column would leave a degenerate table, so
              // the gutter "×" only appears when more than one remains.
              canDeleteRow = rowCount > 1
              canDeleteColumn = (colCount ?? 0) > 1
            }
          }
        },
        { editor }
      )

      if (!tableDOMElement) return

      const {
        width: tableElemWidth,
        y: tableElemY,
        right: tableElemRight,
        left: tableElemLeft,
        bottom: tableElemBottom,
        height: tableElemHeight
      } = tableDOMElement.getBoundingClientRect()

      const parentElement = tableDOMElement.parentElement
      let tableHasScroll = false
      if (parentElement && parentElement.classList.contains("lexical-table-wrapper")) {
        tableHasScroll = parentElement.scrollWidth > parentElement.clientWidth
      }
      const { y: editorElemY, left: editorElemLeft } = anchorElem.getBoundingClientRect()

      // ----- Append "+" bars (last row / last column), unchanged behaviour. -----
      if (hoveredRowNode) {
        const isMac = /^mac/i.test(navigator.platform)

        setShownColumn(false)
        setShownRow(true)
        setPosition({
          height: BUTTON_WIDTH_PX,
          left:
            tableHasScroll && parentElement
              ? parentElement.offsetLeft
              : tableElemLeft - editorElemLeft,
          top: tableElemBottom - editorElemY + (tableHasScroll && !isMac ? 16 : 5),
          width:
            tableHasScroll && parentElement ? parentElement.offsetWidth : tableElemWidth
        })
      } else if (hoveredColumnNode) {
        setShownColumn(true)
        setShownRow(false)
        setPosition({
          height: tableElemHeight,
          left: tableElemRight - editorElemLeft + 5,
          top: tableElemY - editorElemY,
          width: BUTTON_WIDTH_PX
        })
      } else {
        setShownRow(false)
        setShownColumn(false)
      }

      // ----- Delete "×" buttons for the hovered cell's own row and column. -----
      const cellRect = tableDOMNode.getBoundingClientRect()

      if (canDeleteRow) {
        // Vertical strip in the row's left gutter, just outside the table edge.
        setShownDeleteRow(true)
        setDeleteRowPosition({
          top: cellRect.top - editorElemY,
          height: cellRect.height,
          left: Math.max(0, tableElemLeft - editorElemLeft - DELETE_BUTTON_PX - 4),
          width: DELETE_BUTTON_PX
        })
      } else {
        setShownDeleteRow(false)
      }

      if (canDeleteColumn) {
        // Horizontal strip in the column's top gutter, just above the table edge.
        setShownDeleteColumn(true)
        setDeleteColumnPosition({
          left: cellRect.left - editorElemLeft,
          width: cellRect.width,
          top: Math.max(0, tableElemY - editorElemY - DELETE_BUTTON_PX - 4),
          height: DELETE_BUTTON_PX
        })
      } else {
        setShownDeleteColumn(false)
      }
    },
    50,
    250
  )

  // Hide the buttons whenever a table resizes so a button can't end up overlapping
  // a row/column after text entry grows a cell.
  const tableResizeObserver = useMemo(() => {
    return new ResizeObserver(() => {
      hideAll()
    })
  }, [])

  useEffect(() => {
    if (!shouldListenMouseMove) return

    document.addEventListener("mousemove", debouncedOnMouseMove)

    return () => {
      hideAll()
      debouncedOnMouseMove.cancel()
      document.removeEventListener("mousemove", debouncedOnMouseMove)
    }
  }, [shouldListenMouseMove, debouncedOnMouseMove])

  useEffect(() => {
    const unregister = mergeRegister(
      editor.registerMutationListener(
        TableNode,
        (mutations) => {
          editor.getEditorState().read(
            () => {
              let resetObserver = false
              for (const [key, type] of mutations) {
                if (type === "created") {
                  tableSetRef.current.add(key)
                  resetObserver = true
                } else if (type === "destroyed") {
                  tableSetRef.current.delete(key)
                  resetObserver = true
                }
              }
              if (resetObserver) {
                tableResizeObserver.disconnect()
                for (const tableKey of tableSetRef.current) {
                  const { tableElement } = $getTableAndElementByKey(tableKey)
                  // Guard: the key may be destroyed between the mutation batch
                  // and this read, leaving no element to observe.
                  if (tableElement) tableResizeObserver.observe(tableElement)
                }
                setShouldListenMouseMove(tableSetRef.current.size > 0)
              }
            },
            { editor }
          )
        },
        { skipInitialization: false }
      )
    )
    // Disconnect the observer on unmount; mergeRegister only unregisters the
    // mutation listener, so without this the observer leaks table DOM refs
    // across editor open/close cycles.
    return () => {
      unregister()
      tableResizeObserver.disconnect()
    }
  }, [editor, tableResizeObserver])

  const insertAction = (insertRow) => {
    editor.update(() => {
      if (tableCellDOMNodeRef.current) {
        const maybeTableNode = $getNearestNodeFromDOMNode(tableCellDOMNodeRef.current)
        maybeTableNode?.selectEnd()
        if (insertRow) {
          $insertTableRowAtSelection()
          setShownRow(false)
        } else {
          $insertTableColumnAtSelection()
          setShownColumn(false)
        }
      }
    })
  }

  const deleteAction = (deleteRow) => {
    editor.update(() => {
      if (tableCellDOMNodeRef.current) {
        const maybeTableCell = $getNearestNodeFromDOMNode(tableCellDOMNodeRef.current)
        if ($isTableCellNode(maybeTableCell)) {
          // Anchor the selection in the hovered cell so the delete targets its
          // row/column (mousemove never moved the editor selection there).
          maybeTableCell.selectEnd()
          if (deleteRow) {
            $deleteTableRowAtSelection()
            setShownDeleteRow(false)
          } else {
            $deleteTableColumnAtSelection()
            setShownDeleteColumn(false)
          }
        }
      }
    })
  }

  if (!isEditable) return null

  return (
    <>
      {isShownRow && (
        <button
          type="button"
          aria-label="Add row"
          className={`${getTheme()?.tableAddRows}`}
          style={{ ...position }}
          onClick={() => insertAction(true)}
        />
      )}
      {isShownColumn && (
        <button
          type="button"
          aria-label="Add column"
          className={`${getTheme()?.tableAddColumns}`}
          style={{ ...position }}
          onClick={() => insertAction(false)}
        />
      )}
      {isShownDeleteRow && (
        <button
          type="button"
          aria-label="Delete row"
          className={`${getTheme()?.tableDeleteRows}`}
          style={{ ...deleteRowPosition }}
          onClick={() => deleteAction(true)}
        />
      )}
      {isShownDeleteColumn && (
        <button
          type="button"
          aria-label="Delete column"
          className={`${getTheme()?.tableDeleteColumns}`}
          style={{ ...deleteColumnPosition }}
          onClick={() => deleteAction(false)}
        />
      )}
    </>
  )
}

export default function TableHoverActionsPlugin({ anchorElem = document.body } = {}) {
  const isEditable = useLexicalEditable()

  return isEditable
    ? createPortal(<TableHoverActionsContainer anchorElem={anchorElem} />, anchorElem)
    : null
}
