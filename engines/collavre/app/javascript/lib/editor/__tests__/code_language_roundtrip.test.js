/** @jest-environment jsdom */
// Integration test for the markdown→rich language round-trip. Mirrors the
// InlineLexicalEditor wiring: bridge the imported HTML, mark code blocks whose
// language came from an explicit source label, register the detection transform
// that honors resolved languages and only re-detects unlabeled/new blocks.
import { createEditor, $getRoot, $createParagraphNode, $createTextNode, $isTextNode, $isElementNode, $isLineBreakNode } from "lexical"
import { HeadingNode, QuoteNode } from "@lexical/rich-text"
import { ListItemNode, ListNode } from "@lexical/list"
import { LinkNode, AutoLinkNode } from "@lexical/link"
import { CodeNode, CodeHighlightNode, registerCodeHighlighting, $isCodeNode, $createCodeNode } from "@lexical/code"
import { $generateNodesFromDOM } from "@lexical/html"
import { $convertToMarkdownString } from "@lexical/markdown"
import { MARKDOWN_TRANSFORMERS, normalizeMarkdownBlankLines } from "../../lexical/markdown_serialize"
import { renderMarkdown } from "../../utils/markdown"
import {
  bridgeCodeFenceLanguages, detectCodeLanguage, normalizeFenceLang,
  markLanguageResolved, isLanguageResolved, clearLanguageResolved,
} from "../code_languages"

const RUBY = `module CollavreCompat
  module_function
  def call(receiver, method_name, *args, **kwargs)
    params = receiver.method(method_name).parameters
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
    if (detected && detected !== "javascript" && detected !== current) {
      node.setLanguage(detected)
    }
  })
  return editor
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

function codeLang(editor) {
  let lang = null
  editor.read(() => { $getRoot().getChildren().forEach((c) => { if ($isCodeNode(c)) lang = c.getLanguage() }) })
  return lang
}

function fence(editor) {
  let md = ""
  editor.update(() => { md = normalizeMarkdownBlankLines($convertToMarkdownString(MARKDOWN_TRANSFORMERS)) }, { discrete: true })
  return md.split("\n")[0]
}

describe("code-block language round-trip (markdown ↔ rich)", () => {
  test("explicit javascript fence over ruby content is HONORED (not re-detected)", () => {
    const editor = buildEditor()
    loadHtml(editor, renderMarkdown("```javascript\n" + RUBY + "\n```"))
    expect(codeLang(editor)).toBe("javascript")
    expect(fence(editor)).toBe("```javascript")
  })

  test("explicit python fence over ruby content is honored", () => {
    const editor = buildEditor()
    loadHtml(editor, renderMarkdown("```python\n" + RUBY + "\n```"))
    expect(codeLang(editor)).toBe("python")
  })

  test("unlabeled ruby content is auto-detected to ruby", () => {
    const editor = buildEditor()
    loadHtml(editor, renderMarkdown("```\n" + RUBY + "\n```"))
    expect(codeLang(editor)).toBe("ruby")
  })

  test("a NEW (typed) code block still auto-detects from content", () => {
    const editor = buildEditor()
    editor.update(() => {
      const root = $getRoot()
      clearLanguageResolved(editor)
      root.getChildren().forEach((c) => c.remove())
      const code = $createCodeNode() // no language: simulates toolbar insert
      code.append($createTextNode(RUBY))
      root.append(code)
    }, { discrete: true })
    expect(codeLang(editor)).toBe("ruby")
  })

  test("server-reopen form <pre lang=javascript> is also honored", () => {
    const editor = buildEditor()
    loadHtml(editor, '<pre lang="javascript"><code>' + RUBY + "</code></pre>")
    expect(codeLang(editor)).toBe("javascript")
  })
})

import { highlightCodeBlocks } from "../../utils/markdown"

function renderView(html) {
  const div = document.createElement("div")
  div.innerHTML = html
  highlightCodeBlocks(div)
  return div.querySelector("pre code").innerHTML
}

describe("rendered view honors explicit language (edit/view parity)", () => {
  const RUBY_TOKENS = `module M\n  def call(x)\n  end\nend`
  test("explicit javascript is NOT silently re-detected to ruby in the view", () => {
    const asJs = renderView('<pre lang="javascript"><code>' + RUBY_TOKENS + "</code></pre>")
    const asRuby = renderView('<pre lang="ruby"><code>' + RUBY_TOKENS + "</code></pre>")
    // Different tokenizers → different markup. If js were re-detected to ruby
    // they would be identical (the old bug).
    expect(asJs).not.toBe(asRuby)
  })
  test("unlabeled block is content-detected (matches the ruby tokenization)", () => {
    const unlabeled = renderView("<pre><code>" + RUBY_TOKENS + "</code></pre>")
    const asRuby = renderView('<pre lang="ruby"><code>' + RUBY_TOKENS + "</code></pre>")
    expect(unlabeled).toBe(asRuby)
  })
})
