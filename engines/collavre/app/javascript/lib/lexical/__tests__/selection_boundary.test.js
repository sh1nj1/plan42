import {
  createEditor,
  $getRoot,
  $createParagraphNode,
  $createTextNode,
  $getSelection
} from "lexical"
import { registerRichText } from "@lexical/rich-text"
import {
  isSelectionAtDocumentStart,
  isSelectionAtDocumentEnd
} from "../selection_boundary"

function buildEditor() {
  const editor = createEditor({
    namespace: "test",
    onError(error) {
      throw error
    }
  })
  registerRichText(editor)
  return editor
}

// Builds a document with the given lines (one paragraph per line) and places a
// collapsed cursor in the requested paragraph at the requested offset.
function setup(lines, { paragraphIndex, offset }) {
  const editor = buildEditor()
  let result = null
  editor.update(
    () => {
      const root = $getRoot()
      root.clear()
      const textNodes = lines.map((line) => {
        const p = $createParagraphNode()
        const t = $createTextNode(line)
        p.append(t)
        root.append(p)
        return t
      })
      const target = textNodes[paragraphIndex]
      target.select(offset, offset)
    },
    { discrete: true }
  )
  editor.getEditorState().read(() => {
    const selection = $getSelection()
    result = {
      atStart: isSelectionAtDocumentStart(selection),
      atEnd: isSelectionAtDocumentEnd(selection)
    }
  })
  return result
}

describe("selection boundary helpers", () => {
  it("treats cursor at the very start of the first line as document start", () => {
    const r = setup(["line1", "line2"], { paragraphIndex: 0, offset: 0 })
    expect(r.atStart).toBe(true)
  })

  it("does NOT treat start of the second paragraph as document start", () => {
    // This is the bug: after Enter, the cursor sits at offset 0 of a new
    // paragraph. ArrowUp must move the cursor up, not jump to the row above.
    const r = setup(["line1", "line2"], { paragraphIndex: 1, offset: 0 })
    expect(r.atStart).toBe(false)
  })

  it("does NOT treat mid-text cursor as document start", () => {
    const r = setup(["line1"], { paragraphIndex: 0, offset: 2 })
    expect(r.atStart).toBe(false)
  })

  it("treats cursor at the very end of the last line as document end", () => {
    const r = setup(["line1", "line2"], { paragraphIndex: 1, offset: 5 })
    expect(r.atEnd).toBe(true)
  })

  it("does NOT treat end of the first paragraph as document end", () => {
    const r = setup(["line1", "line2"], { paragraphIndex: 0, offset: 5 })
    expect(r.atEnd).toBe(false)
  })

  it("does NOT treat mid-text cursor as document end", () => {
    const r = setup(["line1"], { paragraphIndex: 0, offset: 2 })
    expect(r.atEnd).toBe(false)
  })
})
