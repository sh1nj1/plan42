import { createEditor } from "lexical"
import { $convertFromMarkdownString, $convertToMarkdownString } from "@lexical/markdown"
import { TableNode, TableRowNode, TableCellNode } from "@lexical/table"
import { HeadingNode, QuoteNode } from "@lexical/rich-text"
import { ListNode, ListItemNode } from "@lexical/list"
import { LinkNode } from "@lexical/link"
import { CodeNode, CodeHighlightNode } from "@lexical/code"
import { MARKDOWN_TRANSFORMERS } from "../markdown_serialize"

// Drives a headless editor through markdown -> Lexical -> markdown so the TABLE
// transformer's import (replace) and export paths are exercised together.
function roundTrip(markdown) {
  const editor = createEditor({
    namespace: "table-test",
    onError(error) {
      throw error
    },
    nodes: [
      HeadingNode,
      QuoteNode,
      ListNode,
      ListItemNode,
      LinkNode,
      CodeNode,
      CodeHighlightNode,
      TableNode,
      TableRowNode,
      TableCellNode
    ]
  })
  editor.update(
    () => {
      $convertFromMarkdownString(markdown, MARKDOWN_TRANSFORMERS)
    },
    { discrete: true }
  )
  let result = ""
  editor.getEditorState().read(() => {
    result = $convertToMarkdownString(MARKDOWN_TRANSFORMERS)
  })
  return result
}

describe("TABLE markdown transformer", () => {
  it("round-trips a header + body table", () => {
    const md = "| Name | Age |\n| --- | --- |\n| Ada | 36 |\n| Linus | 54 |"
    const out = roundTrip(md)
    expect(out).toContain("| Name | Age |")
    expect(out).toContain("| --- | --- |")
    expect(out).toContain("| Ada | 36 |")
    expect(out).toContain("| Linus | 54 |")
  })

  it("round-trips a table with an empty cell", () => {
    const md = "| A | B |\n| --- | --- |\n|  | y |"
    const out = roundTrip(md)
    expect(out).toContain("| A | B |")
    expect(out).toContain("|  | y |")
  })

  it("preserves inline formatting inside cells", () => {
    const md = "| H |\n| --- |\n| **bold** |"
    expect(roundTrip(md)).toContain("**bold**")
  })

  it("leaves a non-table paragraph untouched", () => {
    const md = "Just a sentence."
    expect(roundTrip(md).trim()).toBe("Just a sentence.")
  })
})
