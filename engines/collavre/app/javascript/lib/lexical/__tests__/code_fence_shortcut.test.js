import {
  createEditor,
  $getRoot,
  $createParagraphNode,
  $createTextNode,
  $createRangeSelection,
  $setSelection,
  KEY_ENTER_COMMAND
} from "lexical"
import { HeadingNode, QuoteNode, registerRichText } from "@lexical/rich-text"
import { CodeNode, CodeHighlightNode, $isCodeNode } from "@lexical/code"
import { registerCodeFenceShortcut } from "../code_fence_shortcut"
import { isLanguageResolved } from "../../editor/code_languages"

function buildEditor() {
  const editor = createEditor({
    namespace: "test",
    onError(error) {
      throw error
    },
    nodes: [HeadingNode, QuoteNode, CodeNode, CodeHighlightNode]
  })
  registerRichText(editor)
  registerCodeFenceShortcut(editor)
  return editor
}

// Put `text` into a fresh paragraph with the caret at its end — the state right
// before the user presses Enter. This does NOT convert on its own; conversion is
// the Enter keystroke, so the language token can be typed first.
function setFenceLine(editor, text) {
  editor.update(
    () => {
      const root = $getRoot()
      root.clear()
      const paragraph = $createParagraphNode()
      const textNode = $createTextNode(text)
      paragraph.append(textNode)
      root.append(paragraph)
      const selection = $createRangeSelection()
      selection.anchor.set(textNode.getKey(), text.length, "text")
      selection.focus.set(textNode.getKey(), text.length, "text")
      $setSelection(selection)
    },
    { discrete: true }
  )
}

// Dispatch a bare Enter (the fence-commit keystroke). Returns nothing; read the
// editor state afterwards to assert the outcome.
function pressEnter(editor, { shiftKey = false } = {}) {
  editor.dispatchCommand(KEY_ENTER_COMMAND, {
    shiftKey,
    preventDefault() {}
  })
}

describe("registerCodeFenceShortcut", () => {
  it("does not convert until Enter — so ```lang can be typed first", () => {
    const editor = buildEditor()
    // The fence line is present with the caret at its end, but no Enter yet.
    setFenceLine(editor, "```")
    editor.read(() => {
      expect($isCodeNode($getRoot().getFirstChild())).toBe(false)
    })

    // Extending the fence with a language must not have converted it either.
    setFenceLine(editor, "```json")
    editor.read(() => {
      expect($isCodeNode($getRoot().getFirstChild())).toBe(false)
    })
  })

  it("converts a bare ``` fence into an empty code block on Enter", () => {
    const editor = buildEditor()
    setFenceLine(editor, "```")
    pressEnter(editor)

    editor.read(() => {
      const children = $getRoot().getChildren()
      expect(children).toHaveLength(1)
      expect($isCodeNode(children[0])).toBe(true)
      expect(children[0].getTextContent()).toBe("")
      expect(children[0].getLanguage()).toBeFalsy()
    })
  })

  it("carries the language token from ```json on Enter", () => {
    const editor = buildEditor()
    setFenceLine(editor, "```json")
    pressEnter(editor)

    editor.read(() => {
      const codeNode = $getRoot().getFirstChild()
      expect($isCodeNode(codeNode)).toBe(true)
      expect(codeNode.getLanguage()).toBe("json")
    })
  })

  it("marks an explicit fence language resolved so highlighting won't relabel it", () => {
    const editor = buildEditor()
    // ```javascript is ambiguous with the tokenizer's baked default; without the
    // resolved marker the detect transform would re-detect and could relabel it.
    setFenceLine(editor, "```javascript")
    pressEnter(editor)

    let key
    editor.read(() => {
      const codeNode = $getRoot().getFirstChild()
      expect($isCodeNode(codeNode)).toBe(true)
      expect(codeNode.getLanguage()).toBe("javascript")
      key = codeNode.getKey()
    })
    expect(isLanguageResolved(editor, key)).toBe(true)
  })

  it("does not mark a bare ``` fence resolved", () => {
    const editor = buildEditor()
    setFenceLine(editor, "```")
    pressEnter(editor)

    let key
    editor.read(() => {
      key = $getRoot().getFirstChild().getKey()
    })
    expect(isLanguageResolved(editor, key)).toBe(false)
  })

  it("leaves Shift+Enter as a soft newline, not a fence commit", () => {
    const editor = buildEditor()
    setFenceLine(editor, "```")
    pressEnter(editor, { shiftKey: true })

    editor.read(() => {
      expect($isCodeNode($getRoot().getFirstChild())).toBe(false)
    })
  })

  it("leaves prose that merely contains backticks untouched on Enter", () => {
    const editor = buildEditor()
    setFenceLine(editor, "run ```code``` inline")
    pressEnter(editor)

    editor.read(() => {
      const child = $getRoot().getFirstChild()
      expect($isCodeNode(child)).toBe(false)
      expect(child.getTextContent()).toBe("run ```code``` inline")
    })
  })

  it("does not convert a ``` paragraph when the caret is elsewhere", () => {
    const editor = buildEditor()
    editor.update(
      () => {
        const root = $getRoot()
        root.clear()
        const fence = $createParagraphNode()
        fence.append($createTextNode("```"))
        root.append(fence)
        const other = $createParagraphNode()
        const otherText = $createTextNode("elsewhere")
        other.append(otherText)
        root.append(other)
        // Caret sits in the OTHER paragraph, not the fence line.
        const selection = $createRangeSelection()
        selection.anchor.set(otherText.getKey(), 1, "text")
        selection.focus.set(otherText.getKey(), 1, "text")
        $setSelection(selection)
      },
      { discrete: true }
    )
    pressEnter(editor)

    editor.read(() => {
      const children = $getRoot().getChildren()
      expect(children.some($isCodeNode)).toBe(false)
    })
  })
})
