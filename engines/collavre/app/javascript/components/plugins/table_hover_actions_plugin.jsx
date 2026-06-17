import { useEffect, useMemo, useRef, useState } from "react"
import { createPortal } from "react-dom"
import { useLexicalComposerContext } from "@lexical/react/LexicalComposerContext"
import { useLexicalEditable } from "@lexical/react/useLexicalEditable"
import {
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

// Cell-boundary "+" buttons: hover near a table's bottom edge to append a row,
// or near its right edge to append a column. Ported 1:1 from the Lexical
// playground's TableHoverActionsPlugin, adapted to .jsx with the playground's
// getThemeSelector / useDebounce helpers inlined (the playground pulled debounce
// from a transitive lodash-es; we keep a self-contained version instead).

const BUTTON_WIDTH_PX = 20

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
  const [shouldListenMouseMove, setShouldListenMouseMove] = useState(false)
  const [position, setPosition] = useState({})
  const tableSetRef = useRef(new Set())
  const tableCellDOMNodeRef = useRef(null)

  const debouncedOnMouseMove = useDebounce(
    (event) => {
      const { isOutside, tableDOMNode } = getMouseInfo(event, getTheme)

      if (isOutside) {
        setShownRow(false)
        setShownColumn(false)
        return
      }

      if (!tableDOMNode) return

      tableCellDOMNodeRef.current = tableDOMNode

      let hoveredRowNode = null
      let hoveredColumnNode = null
      let tableDOMElement = null

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
            }
          }
        },
        { editor }
      )

      if (tableDOMElement) {
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
        if (
          parentElement &&
          parentElement.classList.contains("lexical-table-wrapper")
        ) {
          tableHasScroll = parentElement.scrollWidth > parentElement.clientWidth
        }
        const { y: editorElemY, left: editorElemLeft } = anchorElem.getBoundingClientRect()

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
        }
      }
    },
    50,
    250
  )

  // Hide the buttons whenever a table resizes so the 'Add Row' button can't end
  // up overlapping the last row after text entry grows a cell.
  const tableResizeObserver = useMemo(() => {
    return new ResizeObserver(() => {
      setShownRow(false)
      setShownColumn(false)
    })
  }, [])

  useEffect(() => {
    if (!shouldListenMouseMove) return

    document.addEventListener("mousemove", debouncedOnMouseMove)

    return () => {
      setShownRow(false)
      setShownColumn(false)
      debouncedOnMouseMove.cancel()
      document.removeEventListener("mousemove", debouncedOnMouseMove)
    }
  }, [shouldListenMouseMove, debouncedOnMouseMove])

  useEffect(() => {
    return mergeRegister(
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
                  tableResizeObserver.observe(tableElement)
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
    </>
  )
}

export default function TableHoverActionsPlugin({ anchorElem = document.body } = {}) {
  const isEditable = useLexicalEditable()

  return isEditable
    ? createPortal(<TableHoverActionsContainer anchorElem={anchorElem} />, anchorElem)
    : null
}
