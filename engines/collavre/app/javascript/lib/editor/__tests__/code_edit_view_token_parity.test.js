/** @jest-environment jsdom */
// Does the LIVE-entered Lexical editor color a JS-fenced block token-for-token
// the same as the rendered view? User report: render → edit shows different
// colors than the view, but refresh/cancel/title agree. This pins whether the
// divergence is in token CLASSES (language/tokenizer) or purely CSS container.
import { createEditor, $getRoot, $createParagraphNode, $isTextNode, $isElementNode, $isLineBreakNode } from "lexical"
import { HeadingNode, QuoteNode } from "@lexical/rich-text"
import { ListItemNode, ListNode } from "@lexical/list"
import { LinkNode, AutoLinkNode } from "@lexical/link"
import { CodeNode, CodeHighlightNode, registerCodeHighlighting, $isCodeNode, $isCodeHighlightNode } from "@lexical/code"
import { $generateNodesFromDOM } from "@lexical/html"
import { renderMarkdown, highlightCodeBlocks } from "../../utils/markdown"
import { CODE_TOKEN_THEME } from "../code_token_theme"
import {
  bridgeCodeFenceLanguages, detectCodeLanguage, normalizeFenceLang,
  markLanguageResolved, isLanguageResolved, clearLanguageResolved,
} from "../code_languages"

const RUBY = `# frozen_string_literal: true

module CollavreCompat
  module_function

  def call(receiver, method_name, *args, **kwargs)
    params = receiver.method(method_name).parameters
    accepted = params.filter_map { |type, name| name if %i[key keyreq].include?(type) }
    receiver.public_send(method_name, *args, **kwargs)
  end
end`

function buildEditor() {
  const editor = createEditor({
    namespace: "test",
    nodes: [HeadingNode, QuoteNode, CodeNode, CodeHighlightNode, ListItemNode, ListNode, LinkNode, AutoLinkNode],
    onError: (e) => { throw e },
  })
  const el = document.createElement("div")
  el.contentEditable = "true"
  document.body.appendChild(el)
  editor.setRootElement(el)
  registerCodeHighlighting(editor)
  editor.registerNodeTransform(CodeNode, (node) => {
    if (isLanguageResolved(editor, node.getKey())) return
    const current = node.getLanguage()
    const norm = normalizeFenceLang(current)
    if (norm && norm !== "javascript") return
    const detected = detectCodeLanguage(node.getTextContent(), current)
    if (detected && detected !== "javascript" && detected !== current) node.setLanguage(detected)
  })
  return { editor, el }
}

function loadHtml(editor, html) {
  editor.update(() => {
    const root = $getRoot()
    clearLanguageResolved(editor)
    root.getChildren().forEach((c) => c.remove())
    const doc = new DOMParser().parseFromString(html || "", "text/html")
    const container = doc.body
    bridgeCodeFenceLanguages(container)
    const nodes = $generateNodesFromDOM(editor, container)
    const mark = (list) => list.forEach((node) => {
      if ($isCodeNode(node)) { if (node.getLanguage()) markLanguageResolved(editor, node.getKey()) }
      else if ($isElementNode(node) && typeof node.getChildren === "function") mark(node.getChildren())
    })
    mark(nodes)
    let pending = null
    const flush = () => { if (pending) { root.append(pending); pending = null } }
    nodes.forEach((node) => {
      const inline = $isTextNode(node) || $isLineBreakNode(node) || ($isElementNode(node) && node.isInline())
      if (inline) { if (!pending) pending = $createParagraphNode(); pending.append(node); return }
      flush(); root.append(node)
    })
    flush()
  }, { discrete: true })
}

// Sequence of [class, text] for every COLORED token span in the VIEW DOM,
// ignoring structure (linebreaks/tabs/untokenized whitespace) — what determines color.
function coloredViewTokens(rootEl) {
  const code = rootEl.querySelector("code") || rootEl
  return Array.from(code.querySelectorAll("span"))
    .filter((s) => /(^|\s)lexical-token-/.test(s.className))
    .map((s) => [s.className, s.textContent])
}

// Same sequence from the EDITOR's node state: each CodeHighlightNode maps its
// highlightType through the SHARED CODE_TOKEN_THEME exactly as the rendered span
// would. Untyped highlight nodes (whitespace) carry no class → excluded, mirroring
// the view's bare-text whitespace.
function coloredEditorTokens(editor) {
  const out = []
  editor.read(() => {
    $getRoot().getChildren().forEach((c) => {
      if (!$isCodeNode(c)) return
      c.getChildren().forEach((child) => {
        if (!$isCodeHighlightNode(child)) return
        const type = child.getHighlightType()
        const cls = type ? CODE_TOKEN_THEME[type] : undefined
        if (cls) out.push([cls, child.getTextContent()])
      })
    })
  })
  return out
}

describe("edit ↔ view token-color parity for explicit javascript", () => {
  test("live-entered editor and rendered view emit the same colored-token sequence", () => {
    const { editor } = buildEditor()
    loadHtml(editor, renderMarkdown("```javascript\n" + RUBY + "\n```"))
    const editorTokens = coloredEditorTokens(editor)

    const viewDiv = document.createElement("div")
    viewDiv.innerHTML = '<pre lang="javascript"><code>' + RUBY.replace(/&/g, "&amp;").replace(/</g, "&lt;") + "</code></pre>"
    highlightCodeBlocks(viewDiv)
    const viewTokens = coloredViewTokens(viewDiv)

    expect(editorTokens.length).toBeGreaterThan(0)
    expect(editorTokens).toEqual(viewTokens)
  })
})
