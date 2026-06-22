/**
 * @jest-environment jsdom
 *
 * Regression for "an external image steals editing focus": clicking into the
 * text to edit while an image is present used to wipe the caret. ImageResizer
 * registered a CLICK_COMMAND handler that called the node-selection hook's
 * setSelected(false) on any click outside the image. That hook, when the live
 * selection is NOT already a NodeSelection (i.e. it is the RangeSelection caret
 * the click just placed), synthesizes a fresh empty NodeSelection and replaces
 * the caret with it — so the editor lost its caret and became uneditable the
 * instant you clicked to edit. The fix uses clearSelection(), which only acts on
 * an existing NodeSelection and leaves a RangeSelection (the caret) intact.
 *
 * ImageResizer is a .jsx React component that can't be imported under this
 * native-ESM jest config, so this test reconstructs the two deselect paths and
 * the exact CLICK_COMMAND handler logic on a headless editor.
 */
import {
  createEditor,
  $getRoot,
  $getSelection,
  $isRangeSelection,
  $isNodeSelection,
  $createNodeSelection,
  $setSelection,
  $createParagraphNode,
  $createTextNode,
  $applyNodeReplacement,
  DecoratorNode,
  CLICK_COMMAND,
  COMMAND_PRIORITY_LOW,
} from "lexical"

class TestImageNode extends DecoratorNode {
  __src
  static getType() { return "image" }
  static clone(n) { return new TestImageNode(n.__src, n.__key) }
  static importJSON() { return $createImage("") }
  constructor(src = "", key) { super(key); this.__src = src }
  createDOM() { return document.createElement("span") }
  updateDOM() { return false }
  decorate() { return null }
}
function $createImage(src) { return $applyNodeReplacement(new TestImageNode(src)) }

// Build: [image][paragraph "hello"] with the caret placed inside the text,
// i.e. the state right after a user clicks into the paragraph to edit.
function setup() {
  const editor = createEditor({ namespace: "t", nodes: [TestImageNode], onError: (e) => { throw e } })
  // jsdom: createEditor needs a root element to dispatch DOM-bound commands.
  const el = document.createElement("div")
  el.contentEditable = "true"
  document.body.appendChild(el)
  editor.setRootElement(el)
  let imageKey
  editor.update(() => {
    const root = $getRoot()
    root.clear()
    root.append($createImage("https://lipcoding.kr/x.png"))
    const p = $createParagraphNode()
    p.append($createTextNode("hello"))
    root.append(p)
    imageKey = root.getFirstChild().getKey()
  }, { discrete: true })
  editor.update(() => {
    $getRoot().getLastChild().getFirstChild().select(2, 2)
  }, { discrete: true })
  return { editor, imageKey }
}

function selKind(editor) {
  let kind = "none"
  editor.getEditorState().read(() => {
    const s = $getSelection()
    if ($isRangeSelection(s)) kind = "range"
    else if ($isNodeSelection(s)) kind = "node"
  })
  return kind
}

// Mirror of the hook's setSelected(false): the OLD, destructive deselect path.
function setSelectedFalse(editor, key) {
  editor.update(() => {
    let selection = $getSelection()
    if (!$isNodeSelection(selection)) {
      selection = $createNodeSelection()
      $setSelection(selection)
    }
    if ($isNodeSelection(selection)) selection.delete(key)
  }, { discrete: true })
}

// Mirror of the hook's clearSelection(): the safe deselect path the fix uses.
function clearSelection(editor) {
  editor.update(() => {
    const selection = $getSelection()
    if ($isNodeSelection(selection)) selection.clear()
  }, { discrete: true })
}

describe("image editing focus", () => {
  test("the old setSelected(false) deselect destroys the caret (documents the bug)", () => {
    const { editor, imageKey } = setup()
    expect(selKind(editor)).toBe("range")
    setSelectedFalse(editor, imageKey)
    expect(selKind(editor)).not.toBe("range") // caret lost — the reported bug
  })

  test("clearSelection() leaves the caret intact", () => {
    const { editor } = setup()
    expect(selKind(editor)).toBe("range")
    clearSelection(editor)
    expect(selKind(editor)).toBe("range")
  })

  test("CLICK_COMMAND outside the image keeps the caret (fixed handler)", () => {
    const { editor } = setup()

    // Stand-in for ImageResizer's container ref; the click target is text
    // outside it, exactly like clicking into the paragraph to edit.
    const container = document.createElement("span")
    const outsideTarget = document.createElement("span")

    editor.registerCommand(
      CLICK_COMMAND,
      (event) => {
        if (container && !container.contains(event.target)) {
          clearSelection(editor) // fixed path (was setSelected(false))
        }
        return false
      },
      COMMAND_PRIORITY_LOW
    )

    expect(selKind(editor)).toBe("range")
    editor.dispatchCommand(CLICK_COMMAND, { target: outsideTarget })
    expect(selKind(editor)).toBe("range") // caret survives the click
  })
})
