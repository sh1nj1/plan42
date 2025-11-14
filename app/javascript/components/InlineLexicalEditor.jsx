import {useCallback, useEffect, useMemo, useRef, useState} from "react"
import {LexicalComposer} from "@lexical/react/LexicalComposer"
import {RichTextPlugin} from "@lexical/react/LexicalRichTextPlugin"
import {ContentEditable} from "@lexical/react/LexicalContentEditable"
import {HistoryPlugin} from "@lexical/react/LexicalHistoryPlugin"
import {OnChangePlugin} from "@lexical/react/LexicalOnChangePlugin"
import {ListPlugin} from "@lexical/react/LexicalListPlugin"
import {LinkPlugin} from "@lexical/react/LexicalLinkPlugin"
import {
  AutoLinkPlugin,
  createLinkMatcherWithRegExp
} from "@lexical/react/LexicalAutoLinkPlugin"
import {LexicalErrorBoundary} from "@lexical/react/LexicalErrorBoundary"
import {HeadingNode, QuoteNode} from "@lexical/rich-text"
import {
  CodeNode,
  CodeHighlightNode,
  $createCodeNode,
  $isCodeNode,
  registerCodeHighlighting
} from "@lexical/code"
import {ListItemNode, ListNode, INSERT_ORDERED_LIST_COMMAND, INSERT_UNORDERED_LIST_COMMAND} from "@lexical/list"
import {LinkNode, AutoLinkNode, TOGGLE_LINK_COMMAND} from "@lexical/link"
import {
  $createParagraphNode,
  $createTextNode,
  $getRoot,
  $getSelection,
  $isElementNode,
  $isRangeSelection,
  $isTextNode,
  CAN_REDO_COMMAND,
  CAN_UNDO_COMMAND,
  COMMAND_PRIORITY_CRITICAL,
  COMMAND_PRIORITY_LOW,
  FORMAT_TEXT_COMMAND,
  REDO_COMMAND,
  SELECTION_CHANGE_COMMAND,
  UNDO_COMMAND
} from "lexical"
import {$patchStyleText} from "@lexical/selection"
import {$generateHtmlFromNodes, $generateNodesFromDOM} from "@lexical/html"
import {useLexicalComposerContext} from "@lexical/react/LexicalComposerContext"
import ActionTextAttachmentPlugin, {
  INSERT_ACTIONTEXT_ATTACHMENT_COMMAND
} from "./plugins/action_text_attachment_plugin"
import {ActionTextAttachmentNode} from "../lib/lexical/action_text_attachment_node"
import {
  canonicalizeAttachmentElements,
  formatFileSize
} from "../lib/lexical/attachment_payload"
import {syncLexicalStyleAttributes} from "../lib/lexical/style_attributes"

const URL_MATCHERS = [
  createLinkMatcherWithRegExp(/https?:\/\/[^\s<]+/gi, (text) => text)
]

const theme = {
  paragraph: "lexical-paragraph",
  quote: "lexical-quote",
  heading: {
    h1: "lexical-heading-h1",
    h2: "lexical-heading-h2",
    h3: "lexical-heading-h3"
  },
  list: {
    ul: "lexical-list-ul",
    ol: "lexical-list-ol",
    listitem: "lexical-list-item"
  },
  code: "lexical-code-block",
  codeHighlight: {
    atrule: "lexical-token-atrule",
    attr: "lexical-token-attr",
    boolean: "lexical-token-boolean",
    builtin: "lexical-token-builtin",
    cdata: "lexical-token-cdata",
    char: "lexical-token-char",
    class: "lexical-token-class",
    comment: "lexical-token-comment",
    constant: "lexical-token-constant",
    deleted: "lexical-token-deleted",
    doctype: "lexical-token-doctype",
    entity: "lexical-token-entity",
    function: "lexical-token-function",
    important: "lexical-token-important",
    inserted: "lexical-token-inserted",
    keyword: "lexical-token-keyword",
    namespace: "lexical-token-namespace",
    number: "lexical-token-number",
    operator: "lexical-token-operator",
    prolog: "lexical-token-prolog",
    property: "lexical-token-property",
    punctuation: "lexical-token-punctuation",
    regex: "lexical-token-regex",
    selector: "lexical-token-selector",
    string: "lexical-token-string",
    symbol: "lexical-token-symbol",
    tag: "lexical-token-tag",
    url: "lexical-token-url",
    variable: "lexical-token-variable"
  },
  link: "lexical-link",
  text: {
    bold: "lexical-text-bold",
    italic: "lexical-text-italic",
    underline: "lexical-text-underline",
    strikethrough: "lexical-text-strike",
    code: "lexical-text-code"
  }
}

function Placeholder({text}) {
  const fallback = "Describe the creative…"
  return <div className="lexical-placeholder">{text || fallback}</div>
}

function InitialContentPlugin({html}) {
  const [editor] = useLexicalComposerContext()
  const lastApplied = useRef(null)

  const collectDomTextStyles = useCallback((container) => {
    const styles = []
    if (!container) return styles
    const ownerDocument = container.ownerDocument || document
    const walker = ownerDocument.createTreeWalker(container, NodeFilter.SHOW_TEXT)
    let current = walker.nextNode()
    while (current) {
      const parent = current.parentElement
      let styleText = parent?.getAttribute?.("style") || ""
      const colorAttr = parent?.dataset?.lexicalColor
      const bgAttr = parent?.dataset?.lexicalBackgroundColor

      if ((!styleText || !styleText.trim()) && (colorAttr || bgAttr)) {
        const declarations = []
        if (colorAttr) declarations.push(`color: ${colorAttr}`)
        if (bgAttr) declarations.push(`background-color: ${bgAttr}`)
        styleText = declarations.join("; ")
      } else {
        const lower = styleText.toLowerCase()
        const fragments = []
        if (colorAttr && !lower.includes("color:")) {
          fragments.push(`color: ${colorAttr}`)
        }
        if (bgAttr && !lower.includes("background-color:")) {
          fragments.push(`background-color: ${bgAttr}`)
        }
        if (fragments.length > 0) {
          styleText = `${styleText}${styleText.trim().endsWith(";") || !styleText.trim() ? "" : ";"} ${fragments.join("; ")}`.trim()
        }
      }

      styles.push(styleText || "")
      current = walker.nextNode()
    }
    return styles
  }, [])

  useEffect(() => {
    if (lastApplied.current === html) return
    lastApplied.current = html
    editor.update(() => {
      const root = $getRoot()
      root.clear()
      const parser = new DOMParser()
      const doc = parser.parseFromString(html || "", "text/html")
      const container = doc.querySelector(".trix-content") || doc.body

      canonicalizeAttachmentElements(container)
      syncLexicalStyleAttributes(container)
      const collectedStyles = collectDomTextStyles(container)

      const nodes = $generateNodesFromDOM(editor, container)
      const appendedNodes = []
      nodes.forEach((node) => {
        if (node instanceof ActionTextAttachmentNode) {
          root.append(node)
          appendedNodes.push(node)
          return
        }

        if ($isTextNode(node)) {
          const paragraph = $createParagraphNode()
          paragraph.append(node)
          root.append(paragraph)
          appendedNodes.push(paragraph)
          return
        }

        if ($isElementNode(node) && node.getType?.() === "paragraph") {
          root.append(node)
          appendedNodes.push(node)
          return
        }

        root.append(node)
        appendedNodes.push(node)
      })

      if (root.getChildrenSize() === 0) {
        const paragraph = $createParagraphNode()
        root.append(paragraph)
        appendedNodes.push(paragraph)
      }

      const children = root.getChildren()
      let previousAttachmentMeta = null
      const nodesToRemove = []
      children.forEach((child) => {
        if (child instanceof ActionTextAttachmentNode) {
          const payload = child.getPayload?.()
          previousAttachmentMeta = payload
          return
        }

        if (previousAttachmentMeta && child.getType?.() === "paragraph") {
          const textContent = child.getTextContent?.().trim() || ""
          const expected = new Set()
          if (previousAttachmentMeta.filename) {
            expected.add(previousAttachmentMeta.filename)
          }
          if (
            previousAttachmentMeta.filename &&
            Number.isFinite(previousAttachmentMeta.filesize)
          ) {
            expected.add(
              `${previousAttachmentMeta.filename} ${formatFileSize(previousAttachmentMeta.filesize)}`
            )
          }
          if (expected.has(textContent) || !textContent) {
            nodesToRemove.push(child)
            previousAttachmentMeta = null
            return
          }
        }

        previousAttachmentMeta = null
      })

      nodesToRemove.forEach((node) => {
        if (node.getParent() === root) {
          node.remove()
        }
      })

      const textNodes = root.getAllTextNodes()
      textNodes.forEach((textNode, index) => {
        const style = collectedStyles[index]
        textNode.setStyle(style || "")
      })

      let lastChild = root.getLastChild()
      while (
        lastChild &&
        lastChild.getType?.() === "paragraph" &&
        lastChild.getChildrenSize?.() === 0
      ) {
        lastChild.remove()
        lastChild = root.getLastChild()
      }

      if (root.getChildrenSize() === 0) {
        root.append($createParagraphNode())
      }
    })
  }, [collectDomTextStyles, editor, html])

  return null
}

function LinkAttributesPlugin() {
  const [editor] = useLexicalComposerContext()

  useEffect(() => {
    return editor.registerUpdateListener(() => {
      const rootElement = editor.getRootElement()
      if (!rootElement) return
      rootElement.querySelectorAll("a").forEach((anchor) => {
        if (!anchor.getAttribute("target")) {
          anchor.setAttribute("target", "_blank")
        }
        const rel = anchor.getAttribute("rel") || ""
        if (!rel.includes("noopener")) {
          anchor.setAttribute("rel", (rel + " noopener").trim())
        }
      })
    })
  }, [editor])

  return null
}

function CodeHighlightingPlugin() {
  const [editor] = useLexicalComposerContext()

  useEffect(() => {
    return registerCodeHighlighting(editor)
  }, [editor])

  return null
}

function ToolbarColorPicker({icon, title, color, onChange, onClear}) {
  const [open, setOpen] = useState(false)
  const triggerRef = useRef(null)
  const popoverRef = useRef(null)

  useEffect(() => {
    if (!open) return
    const handleClick = (event) => {
      if (
        popoverRef.current &&
        !popoverRef.current.contains(event.target) &&
        triggerRef.current &&
        !triggerRef.current.contains(event.target)
      ) {
        setOpen(false)
      }
    }
    document.addEventListener("mousedown", handleClick)
    return () => document.removeEventListener("mousedown", handleClick)
  }, [open])

  return (
    <div className="lexical-toolbar-color" title={title}>
      <button
        type="button"
        className="lexical-toolbar-btn lexical-toolbar-color__trigger"
        onClick={() => setOpen((prev) => !prev)}
        ref={triggerRef}>
        <span className="lexical-toolbar-color__swatch" style={{backgroundColor: color}} />
        {icon}
      </button>
      {open ? (
        <div className="lexical-toolbar-color__popover" ref={popoverRef}>
          <input
            type="color"
            value={color}
            onChange={(event) => onChange(event.target.value)}
          />
          <button
            type="button"
            className="lexical-toolbar-btn lexical-toolbar-btn--small"
            onClick={() => {
              onClear()
              setOpen(false)
            }}>
            ✕
          </button>
        </div>
      ) : null}
    </div>
  )
}

function Toolbar({onPromptForLink}) {
  const [editor] = useLexicalComposerContext()
  const [formats, setFormats] = useState({
    bold: false,
    italic: false,
    underline: false,
    strike: false
  })
  const [isCodeBlock, setIsCodeBlock] = useState(false)
  const [canUndo, setCanUndo] = useState(false)
  const [canRedo, setCanRedo] = useState(false)
  const imageInputRef = useRef(null)
  const fileInputRef = useRef(null)
  const DEFAULT_FONT_COLOR = "#000000"
  const DEFAULT_BG_COLOR = "#ffffff"
  const [fontColor, setFontColor] = useState(DEFAULT_FONT_COLOR)
  const [bgColor, setBgColor] = useState(DEFAULT_BG_COLOR)

  const handleFiles = useCallback(
    (fileList, options = {}) => {
      if (!fileList) return
      Array.from(fileList).forEach((file) => {
        if (file) {
          editor.dispatchCommand(INSERT_ACTIONTEXT_ATTACHMENT_COMMAND, {
            file,
            options
          })
        }
      })
    },
    [editor]
  )

  const openImagePicker = useCallback(() => {
    imageInputRef.current?.click()
  }, [])

  const openFilePicker = useCallback(() => {
    fileInputRef.current?.click()
  }, [])

  const refreshFormats = useCallback(() => {
    const selection = $getSelection()
    if (!$isRangeSelection(selection)) {
      setIsCodeBlock(false)
      return
    }
    setFormats({
      bold: selection.hasFormat("bold"),
      italic: selection.hasFormat("italic"),
      underline: selection.hasFormat("underline"),
      strike: selection.hasFormat("strikethrough")
    })
    const anchor = selection.anchor.getNode()
    const topLevel = anchor.getTopLevelElement()
    setIsCodeBlock(Boolean(topLevel && $isCodeNode(topLevel)))
  }, [])

  useEffect(() => {
    return editor.registerCommand(
      SELECTION_CHANGE_COMMAND,
      () => {
        editor.getEditorState().read(refreshFormats)
        return false
      },
      COMMAND_PRIORITY_LOW
    )
  }, [editor, refreshFormats])

  useEffect(() => {
    return editor.registerCommand(
      CAN_UNDO_COMMAND,
      (payload) => {
        setCanUndo(payload)
        return false
      },
      COMMAND_PRIORITY_CRITICAL
    )
  }, [editor])

  useEffect(() => {
    return editor.registerCommand(
      CAN_REDO_COMMAND,
      (payload) => {
        setCanRedo(payload)
        return false
      },
      COMMAND_PRIORITY_CRITICAL
    )
  }, [editor])

  useEffect(() => {
    return editor.registerUpdateListener(({editorState}) => {
      editorState.read(refreshFormats)
    })
  }, [editor, refreshFormats])

  const toggleFormat = useCallback(
    (type) => {
      editor.dispatchCommand(FORMAT_TEXT_COMMAND, type)
    },
    [editor]
  )

  const toggleList = useCallback(
    (type) => {
      const command =
        type === "number" ? INSERT_ORDERED_LIST_COMMAND : INSERT_UNORDERED_LIST_COMMAND
      editor.dispatchCommand(command)
    },
    [editor]
  )

  const toggleLink = useCallback(() => {
    const selection = $getSelection()
    if (!$isRangeSelection(selection)) return
    const hasLink = selection.getNodes().some((node) => {
      if (node.getType() === "link") return true
      const parent = node.getParent()
      return parent?.getType() === "link"
    })
    if (hasLink) {
      editor.dispatchCommand(TOGGLE_LINK_COMMAND, null)
      return
    }
    const nextUrl = onPromptForLink?.()
    if (nextUrl) {
      editor.dispatchCommand(TOGGLE_LINK_COMMAND, nextUrl)
    }
  }, [editor, onPromptForLink])

  const applyTextStyle = useCallback(
    (style) => {
      editor.update(() => {
        const selection = $getSelection()
        if ($isRangeSelection(selection)) {
          $patchStyleText(selection, style)
        }
      })
    },
    [editor]
  )

  const toggleCodeBlock = useCallback(() => {
    editor.update(() => {
      const selection = $getSelection()
      if (!$isRangeSelection(selection)) return

      const anchorNode = selection.anchor.getNode()
      const topLevel = anchorNode.getTopLevelElement()
      if (!topLevel) return

      if ($isCodeNode(topLevel)) {
        const textContent = topLevel.getTextContent()
        const lines = textContent.split("\n")
        const firstParagraph = $createParagraphNode()
        firstParagraph.append($createTextNode(lines[0] || ""))
        topLevel.replace(firstParagraph)
        let previous = firstParagraph
        for (let index = 1; index < lines.length; index += 1) {
          const paragraph = $createParagraphNode()
          paragraph.append($createTextNode(lines[index]))
          previous.insertAfter(paragraph)
          previous = paragraph
        }
        firstParagraph.selectEnd()
        return
      }

      if (topLevel.getType?.() !== "paragraph") {
        return
      }

      const codeNode = $createCodeNode()
      const content = topLevel.getTextContent()
      codeNode.append($createTextNode(content || ""))
      topLevel.replace(codeNode)
      codeNode.selectEnd()
    })
  }, [editor])

  return (
    <div className="lexical-toolbar">
      <button
        type="button"
        className="lexical-toolbar-btn"
        onClick={() => editor.dispatchCommand(UNDO_COMMAND, undefined)}
        disabled={!canUndo}
        title="Undo (⌘/Ctrl+Z)"
        aria-label="Undo">
          ↩
      </button>
      <button
        type="button"
        className="lexical-toolbar-btn"
        onClick={() => editor.dispatchCommand(REDO_COMMAND, undefined)}
        disabled={!canRedo}
        title="Redo (⇧⌘/Ctrl+Z)"
        aria-label="Redo">
          ↪
      </button>
      <span className="lexical-toolbar-separator" aria-hidden="true" />
      <button
        type="button"
        className={`lexical-toolbar-btn ${formats.bold ? "active" : ""}`}
        onClick={() => toggleFormat("bold")}
        title="Bold (⌘/Ctrl+B)">
        B
      </button>
      <button
        type="button"
        className={`lexical-toolbar-btn ${formats.italic ? "active" : ""}`}
        onClick={() => toggleFormat("italic")}
        title="Italic (⌘/Ctrl+I)">
        I
      </button>
      <button
        type="button"
        className={`lexical-toolbar-btn ${formats.underline ? "active" : ""}`}
        onClick={() => toggleFormat("underline")}
        title="Underline (⌘/Ctrl+U)">
        U
      </button>
      <button
        type="button"
        className={`lexical-toolbar-btn ${formats.strike ? "active" : ""}`}
        onClick={() => toggleFormat("strikethrough")}
        title="Strikethrough">
        S
      </button>
      <button
        type="button"
        className={`lexical-toolbar-btn ${isCodeBlock ? "active" : ""}`}
        onClick={toggleCodeBlock}
        title="Code block">
        {'</>'}
      </button>
      <span className="lexical-toolbar-separator" aria-hidden="true" />
      <button
        type="button"
        className="lexical-toolbar-btn"
        onClick={() => toggleList("bullet")}
        title="Bulleted list">
        ••
      </button>
      <button
        type="button"
        className="lexical-toolbar-btn"
        onClick={() => toggleList("number")}
        title="Numbered list">
        1.
      </button>
      <span className="lexical-toolbar-separator" aria-hidden="true" />
      <button
        type="button"
        className="lexical-toolbar-btn"
        onClick={toggleLink}
        title="Insert link">
        🔗
      </button>
      <span className="lexical-toolbar-separator" aria-hidden="true" />
      <ToolbarColorPicker
        icon="🎨"
        title="Text color"
        color={fontColor}
        onChange={(value) => {
          setFontColor(value)
          applyTextStyle({color: value})
        }}
        onClear={() => {
          setFontColor(DEFAULT_FONT_COLOR)
          applyTextStyle({color: ""})
        }}
      />
      <ToolbarColorPicker
        icon="🖌️"
        title="Background color"
        color={bgColor}
        onChange={(value) => {
          setBgColor(value)
          applyTextStyle({backgroundColor: value})
        }}
        onClear={() => {
          setBgColor(DEFAULT_BG_COLOR)
          applyTextStyle({backgroundColor: ""})
        }}
      />
      <span className="lexical-toolbar-separator" aria-hidden="true" />
      <input
        ref={imageInputRef}
        type="file"
        accept="image/*"
        style={{display: "none"}}
        onChange={(event) => {
          handleFiles(event.target.files, {kind: "image"})
          event.target.value = ""
        }}
      />
      <input
        ref={fileInputRef}
        type="file"
        style={{display: "none"}}
        onChange={(event) => {
          handleFiles(event.target.files)
          event.target.value = ""
        }}
      />
      <button
        type="button"
        className="lexical-toolbar-btn"
        onClick={openImagePicker}
        title="Insert image">
        🖼️
      </button>
      <button
        type="button"
        className="lexical-toolbar-btn"
        onClick={openFilePicker}
        title="Attach file">
        📎
      </button>
    </div>
  )
}

function ReadyPlugin({onReady}) {
  const [editor] = useLexicalComposerContext()

  useEffect(() => {
    if (!onReady) return
    onReady({
      focus: () => {
        editor.focus(() => {
          editor.getRootElement()?.focus()
        })
      },
      getEditor: () => editor
    })
  }, [editor, onReady])

  return null
}

function EditorInner({
  initialHtml,
  onChange,
  onKeyDown,
  onPromptForLink,
  onReady,
  onUploadStateChange,
  directUploadUrl,
  blobUrlTemplate,
  placeholderText
}) {
  const [editor] = useLexicalComposerContext()

  return (
    <div className="lexical-editor-shell">
      <Toolbar onPromptForLink={onPromptForLink} />
      <div className="lexical-editor-inner">
        <RichTextPlugin
          contentEditable={
            <ContentEditable
              className="lexical-content-editable shared-input-surface"
              onKeyDown={(event) => {
                if (!onKeyDown) return
                onKeyDown(event, editor)
              }}
            />
          }
          placeholder={<Placeholder text={placeholderText} />}
          ErrorBoundary={LexicalErrorBoundary}
        />
        <HistoryPlugin />
        <CodeHighlightingPlugin />
        <ListPlugin />
        <LinkPlugin />
        <AutoLinkPlugin matchers={URL_MATCHERS} />
        <OnChangePlugin
          onChange={(editorState, editorInstance) => {
            if (!onChange) return
            let serialized = ""
            editorState.read(() => {
              const innerHtml = $generateHtmlFromNodes(editorInstance)
              const parser = new DOMParser()
              const doc = parser.parseFromString(`<div>${innerHtml}</div>`, "text/html")

              canonicalizeAttachmentElements(doc.body)
              syncLexicalStyleAttributes(doc.body)

              doc.querySelectorAll("action-text-attachment").forEach((attachment) => {
                const containerParagraph = attachment.closest("p")
                let sibling = containerParagraph?.nextElementSibling
                while (sibling && sibling.tagName === "BR") {
                  const toRemove = sibling
                  sibling = sibling.nextElementSibling
                  toRemove.remove()
                }
                if (
                  sibling &&
                  sibling.tagName === "P" &&
                  !sibling.querySelector("action-text-attachment")
                ) {
                  const text = sibling.textContent || ""
                  const hasContent = text.replace(/\s|\u00A0/g, "") !== ""
                  const hasNonBr = Array.from(sibling.childNodes).some((node) => {
                    return !(node.nodeType === Node.ELEMENT_NODE && node.tagName === "BR")
                  })
                  if (!hasContent && !hasNonBr) {
                    sibling.remove()
                  }
                }
              })
              const bodyChildren = Array.from(doc.body.children)
              for (let i = bodyChildren.length - 1; i >= 0; i -= 1) {
                const element = bodyChildren[i]
                if (element.tagName !== "P") break
                if (element.querySelector("action-text-attachment")) break
                const text = element.textContent || ""
                const hasContent = text.replace(/\s|\u00A0/g, "") !== ""
                const hasNonBr = Array.from(element.childNodes).some((node) => {
                  return !(node.nodeType === Node.ELEMENT_NODE && node.tagName === "BR")
                })
                if (!hasContent && !hasNonBr) {
                  element.remove()
                  continue
                }
                break
              }
              doc.querySelectorAll("a").forEach((anchor) => {
                anchor.setAttribute("target", "_blank")
                anchor.setAttribute("rel", "noopener")
              })
              serialized = doc.body.innerHTML
            })
            const safeHtml = serialized || "<div><br></div>"
            const wrapped = `<div class="trix-content">${safeHtml}</div>`
            onChange(wrapped)
          }}
        />
        <InitialContentPlugin html={initialHtml} />
        <LinkAttributesPlugin />
        <ReadyPlugin onReady={onReady} />
        <ActionTextAttachmentPlugin
          onUploadStateChange={onUploadStateChange}
          directUploadUrl={directUploadUrl}
          blobUrlTemplate={blobUrlTemplate}
        />
      </div>
    </div>
  )
}

export default function InlineLexicalEditor({
  initialHtml,
  onChange,
  onKeyDown,
  onPromptForLink,
  onReady,
  onUploadStateChange,
  directUploadUrl,
  blobUrlTemplate,
  editorKey,
  placeholderText
}) {
  const initialConfig = useMemo(
    () => ({
      namespace: "CreativeLexicalEditor",
      nodes: [
        HeadingNode,
        QuoteNode,
        CodeNode,
        CodeHighlightNode,
        ListItemNode,
        ListNode,
        LinkNode,
        AutoLinkNode,
        ActionTextAttachmentNode
      ],
      onError(error) {
        throw error
      },
      theme
    }),
    []
  )

  return (
    <LexicalComposer key={editorKey} initialConfig={initialConfig}>
      <EditorInner
        initialHtml={initialHtml}
        onChange={onChange}
        onKeyDown={onKeyDown}
        onPromptForLink={onPromptForLink}
        onReady={onReady}
        onUploadStateChange={onUploadStateChange}
        directUploadUrl={directUploadUrl}
        blobUrlTemplate={blobUrlTemplate}
        placeholderText={placeholderText}
      />
    </LexicalComposer>
  )
}
