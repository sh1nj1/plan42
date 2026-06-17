/**
 * @jest-environment jsdom
 */
import {
  createEditor,
  $getRoot,
  $createParagraphNode,
  $createTextNode
} from "lexical"
import { registerRichText } from "@lexical/rich-text"
import { CodeNode, $createCodeNode } from "@lexical/code"
import { LinkNode, $createLinkNode } from "@lexical/link"
import { buildFlatText } from "../../../lib/lexical_typo_text"
import { EditorTypoController } from "../typo_correction_plugin"

// jsdom has no layout engine, so the overlay rect math (getClientRects) can't be
// exercised here — that is verified in a real headless browser. These tests pin
// the parts that don't need layout: which text is sent to the server, that
// auto-apply rewrites the editor text, and the headline guarantee that a
// highlight never enters the editor state (so markdown-canonical storage is
// safe).

const settings = {
  enabled: true,
  threshold: 80,
  onVoice: true,
  onSoftKeyboard: true,
  onPhysicalKeyboard: true,
  inChat: true,
  inEditor: true,
}

function mount() {
  document.body.innerHTML = '<div class="lexical-editor-inner"><div class="root" contenteditable="true"></div></div>'
  const rootEl = document.querySelector(".root")
  const editor = createEditor({
    namespace: "typo-test",
    onError(error) { throw error },
    nodes: [CodeNode, LinkNode],
  })
  registerRichText(editor)
  editor.setRootElement(rootEl)
  return { editor, rootEl }
}

function controllerFor(editor) {
  return new EditorTypoController(editor, {
    settings, endpoint: "/typo_corrections", labels: {}, getVoiceActive: () => false,
  })
}

afterEach(() => { document.body.innerHTML = "" })

test("collects plain text but excludes code-block and link text (protected spans)", () => {
  const { editor } = mount()
  editor.update(() => {
    const root = $getRoot()
    root.clear()
    const p = $createParagraphNode()
    p.append($createTextNode("vist "))
    const link = $createLinkNode("https://example.com")
    link.append($createTextNode("teh-site"))
    p.append(link)
    const code = $createCodeNode()
    code.append($createTextNode("teh code"))
    root.append(p, code)
  }, { discrete: true })

  const controller = controllerFor(editor)
  const { text } = buildFlatText(controller._collectSegments())
  controller.destroy()

  expect(text).toContain("vist ")
  expect(text).not.toContain("teh-site") // link text excluded
  expect(text).not.toContain("teh code") // code-block text excluded
})

test("auto-applies a high-confidence edit into the editor text", () => {
  const { editor } = mount()
  editor.update(() => {
    const root = $getRoot()
    root.clear()
    const p = $createParagraphNode()
    p.append($createTextNode("잇습니다 그리고"))
    root.append(p)
  }, { discrete: true })

  const controller = controllerFor(editor)
  controller._applyResult("잇습니다 그리고", {
    edits: [{ original: "잇습니다", suggestion: "있습니다", confidence: 0.95 }],
    threshold: 80,
  })

  let textContent = ""
  editor.read(() => { textContent = $getRoot().getTextContent() })
  controller.destroy()
  expect(textContent).toBe("있습니다 그리고")
})

test("the highlight never enters the editor state (markdown-canonical safe)", () => {
  const { editor, rootEl } = mount()
  editor.update(() => {
    const root = $getRoot()
    root.clear()
    const p = $createParagraphNode()
    p.append($createTextNode("teh cat"))
    root.append(p)
  }, { discrete: true })

  const controller = controllerFor(editor)
  // A low-confidence candidate: a mark is tracked, but the text is untouched and
  // no mark node is inserted into the editor's own DOM/state.
  controller._applyResult("teh cat", {
    edits: [{ original: "teh", suggestion: "the", confidence: 0.4 }],
    threshold: 80,
  })

  let textContent = ""
  let childTypes = []
  editor.read(() => {
    const root = $getRoot()
    textContent = root.getTextContent()
    childTypes = root.getChildren().flatMap((b) => b.getChildren?.().map((c) => c.getType()) || [])
  })
  // The candidate mark is tracked off to the side (volatile), text unchanged.
  expect(textContent).toBe("teh cat")
  expect(controller.marks.length).toBe(1)
  // No 'mark'/decorator node leaked into the editor state, and the editor's own
  // DOM carries no overlay marks (those live on the separate overlay layer).
  expect(childTypes).not.toContain("mark")
  expect(rootEl.querySelector(".typo-mark")).toBeNull()
  controller.destroy()
})
