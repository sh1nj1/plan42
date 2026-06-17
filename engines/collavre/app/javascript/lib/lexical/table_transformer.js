import {
  $createTableCellNode,
  $createTableNode,
  $createTableRowNode,
  $isTableCellNode,
  $isTableNode,
  $isTableRowNode,
  TableCellHeaderStates
} from "@lexical/table"
import { $convertFromMarkdownString, $convertToMarkdownString } from "@lexical/markdown"
import { $isParagraphNode, $isTextNode } from "lexical"

// GFM pipe-table support for the markdown-canonical editor. Ported from the
// Lexical playground's MarkdownTransformers TABLE ElementTransformer, adapted to
// .js and to a lazily-injected cell transformer list. Unlike the color/decorator
// transformers (export-only), this one is bidirectional: it exports Lexical
// tables to GFM and reconstructs them when markdown is parsed back.

const TABLE_ROW_REG_EXP = /^(?:\|)(.+)(?:\|)\s?$/
// -+ (not -*) is required per cell: a GFM divider must have at least one dash,
// and the mandatory dash run anchors the surrounding :? colons so they can't both
// compete for the same character — which would cause exponential backtracking.
const TABLE_ROW_DIVIDER_REG_EXP = /^(\| ?:?-+:? ?)+\|\s?$/

// Each table cell is (de)serialized with the full transformer list (which
// includes this TABLE transformer). markdown_serialize.js injects the list once
// at load via setCellTransformers to avoid a circular import. Cells never nest
// tables, so the self-reference stays bounded.
let cellTransformers = []
export function setCellTransformers(list) {
  cellTransformers = list
}

function getTableColumnsSize(table) {
  const row = table.getFirstChild()
  return $isTableRowNode(row) ? row.getChildrenSize() : 0
}

function $createTableCell(textContent) {
  const text = textContent.replace(/\\n/g, "\n")
  const cell = $createTableCellNode(TableCellHeaderStates.NO_STATUS)
  $convertFromMarkdownString(text, cellTransformers, cell)
  return cell
}

function mapToTableCells(textContent) {
  const match = textContent.match(TABLE_ROW_REG_EXP)
  if (!match || !match[1]) return null
  return match[1].split("|").map((text) => $createTableCell(text))
}

export const TABLE = {
  dependencies: [],
  export: (node) => {
    if (!$isTableNode(node)) return null
    const output = []
    for (const row of node.getChildren()) {
      if (!$isTableRowNode(row)) continue
      const rowOutput = []
      let isHeaderRow = false
      for (const cell of row.getChildren()) {
        if ($isTableCellNode(cell)) {
          rowOutput.push(
            $convertToMarkdownString(cellTransformers, cell).replace(/\n/g, "\\n").trim()
          )
          if (cell.__headerState === TableCellHeaderStates.ROW) {
            isHeaderRow = true
          }
        }
      }
      output.push(`| ${rowOutput.join(" | ")} |`)
      if (isHeaderRow) {
        output.push(`| ${rowOutput.map(() => "---").join(" | ")} |`)
      }
    }
    return output.join("\n")
  },
  regExp: TABLE_ROW_REG_EXP,
  replace: (parentNode, _children, match) => {
    // A divider row ("| --- | --- |") promotes the previous table's last row to
    // a header row, then removes itself.
    if (TABLE_ROW_DIVIDER_REG_EXP.test(match[0])) {
      const table = parentNode.getPreviousSibling()
      if (!table || !$isTableNode(table)) return
      const rows = table.getChildren()
      const lastRow = rows[rows.length - 1]
      if (!lastRow || !$isTableRowNode(lastRow)) return
      lastRow.getChildren().forEach((cell) => {
        if (!$isTableCellNode(cell)) return
        cell.setHeaderStyles(TableCellHeaderStates.ROW, TableCellHeaderStates.ROW)
      })
      parentNode.remove()
      return
    }

    const matchCells = mapToTableCells(match[0])
    if (matchCells == null) return

    // Walk backwards over preceding single-text paragraphs that are also table
    // rows, accumulating them so a multi-line table is parsed as one node.
    const rows = [matchCells]
    let sibling = parentNode.getPreviousSibling()
    let maxCells = matchCells.length
    while (sibling) {
      if (!$isParagraphNode(sibling) || sibling.getChildrenSize() !== 1) break
      const firstChild = sibling.getFirstChild()
      if (!$isTextNode(firstChild)) break
      const cells = mapToTableCells(firstChild.getTextContent())
      if (cells == null) break
      maxCells = Math.max(maxCells, cells.length)
      rows.unshift(cells)
      const previousSibling = sibling.getPreviousSibling()
      sibling.remove()
      sibling = previousSibling
    }

    const table = $createTableNode()
    for (const cells of rows) {
      const tableRow = $createTableRowNode()
      table.append(tableRow)
      for (let i = 0; i < maxCells; i++) {
        tableRow.append(i < cells.length ? cells[i] : $createTableCell(""))
      }
    }

    // Merge with an adjacent table of the same width (the divider row already
    // removed itself, leaving the header table directly before this body row).
    const previousSibling = parentNode.getPreviousSibling()
    if ($isTableNode(previousSibling) && getTableColumnsSize(previousSibling) === maxCells) {
      previousSibling.append(...table.getChildren())
      parentNode.remove()
    } else {
      parentNode.replace(table)
    }
    table.selectEnd()
  },
  type: "element"
}
