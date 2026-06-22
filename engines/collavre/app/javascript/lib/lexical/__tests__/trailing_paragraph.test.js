/**
 * @jest-environment jsdom
 */
import {
  createEditor,
  $getRoot,
  $createParagraphNode,
  $createTextNode,
  $applyNodeReplacement,
  DecoratorNode,
} from "lexical"
import { ensureTrailingParagraph, registerTrailingParagraph } from "../trailing_paragraph"

// Stand-in for the production image/video/attachment nodes (those are .jsx and
// can't be imported here). Only the graph-relevant shape matters: a "image"
// DecoratorNode that is NOT inline, exactly like image_node.jsx.
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

function newEditor() {
  return createEditor({ namespace: "t", nodes: [TestImageNode], onError: (e) => { throw e } })
}

function rootTypes(editor) {
  let types = []
  editor.getEditorState().read(() => {
    types = $getRoot().getChildren().map((c) => c.getType())
  })
  return types
}

describe("ensureTrailingParagraph (pure helper)", () => {
  test("appends a paragraph when the last root child is a decorator", () => {
    const editor = newEditor()
    editor.update(() => {
      const root = $getRoot()
      root.clear()
      const p = $createParagraphNode()
      p.append($createTextNode("hello"))
      root.append(p, $createImage("https://lipcoding.kr/x.png"))
      ensureTrailingParagraph(root)
    }, { discrete: true })
    expect(rootTypes(editor)).toEqual(["paragraph", "image", "paragraph"])
  })

  test("image-only content becomes editable (image + trailing paragraph)", () => {
    const editor = newEditor()
    editor.update(() => {
      const root = $getRoot()
      root.clear()
      root.append($createImage("https://lipcoding.kr/x.png"))
      ensureTrailingParagraph(root)
    }, { discrete: true })
    expect(rootTypes(editor)).toEqual(["image", "paragraph"])
  })

  test("no-op when the last child is already a paragraph", () => {
    const editor = newEditor()
    editor.update(() => {
      const root = $getRoot()
      root.clear()
      root.append($createImage("a"), $createParagraphNode())
      ensureTrailingParagraph(root)
    }, { discrete: true })
    expect(rootTypes(editor)).toEqual(["image", "paragraph"])
  })
})

describe("registerTrailingParagraph (RootNode transform)", () => {
  test("fires on update: trailing image gets a paragraph appended automatically", () => {
    const editor = newEditor()
    registerTrailingParagraph(editor)
    // Simulate editing that leaves an image as the last block.
    editor.update(() => {
      const root = $getRoot()
      root.clear()
      const p = $createParagraphNode()
      p.append($createTextNode("hello"))
      root.append(p, $createImage("https://lipcoding.kr/x.png"))
    }, { discrete: true })
    expect(rootTypes(editor)).toEqual(["paragraph", "image", "paragraph"])
  })

  test("terminates (does not append unboundedly)", () => {
    const editor = newEditor()
    registerTrailingParagraph(editor)
    editor.update(() => {
      const root = $getRoot()
      root.clear()
      root.append($createImage("a"))
    }, { discrete: true })
    // exactly one trailing paragraph, not many
    expect(rootTypes(editor)).toEqual(["image", "paragraph"])
  })
})
