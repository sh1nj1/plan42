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
  COMMAND_PRIORITY_LOW,
  FORMAT_TEXT_COMMAND,
  SELECTION_CHANGE_COMMAND
} from "lexical"
import {$generateHtmlFromNodes, $generateNodesFromDOM} from "@lexical/html"
import {useLexicalComposerContext} from "@lexical/react/LexicalComposerContext"
import ActionTextAttachmentPlugin, {
  INSERT_ACTIONTEXT_ATTACHMENT_COMMAND
} from "./plugins/action_text_attachment_plugin"
import {ActionTextAttachmentNode} from "../lib/lexical/action_text_attachment_node"

function formatFileSize(bytes) {
  if (!Number.isFinite(bytes) || bytes <= 0) return ""
  const units = ["B", "KB", "MB", "GB", "TB"]
  let size = bytes
  let unitIndex = 0
  while (size >= 1024 && unitIndex < units.length - 1) {
    size /= 1024
    unitIndex += 1
  }
  return `${size % 1 === 0 ? size : size.toFixed(1)} ${units[unitIndex]}`
}

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
  link: "lexical-link",
  text: {
    bold: "lexical-text-bold",
    italic: "lexical-text-italic",
    underline: "lexical-text-underline",
    strikethrough: "lexical-text-strike",
    code: "lexical-text-code"
  }
}

function Placeholder() {
  return <div className="lexical-placeholder">Describe the creative…</div>
}

function InitialContentPlugin({html}) {
  const [editor] = useLexicalComposerContext()
  const lastApplied = useRef(null)

  useEffect(() => {
    if (lastApplied.current === html) return
    lastApplied.current = html
    editor.update(() => {
      const root = $getRoot()
      root.clear()
      const parser = new DOMParser()
      const doc = parser.parseFromString(html || "", "text/html")
      const container = doc.querySelector(".trix-content") || doc.body
      const attachmentElements = Array.from(container.querySelectorAll("action-text-attachment"))
      const attachmentBySgid = new Set()
      const attachmentByName = new Set()
      const attachmentByUrl = new Set()
      attachmentElements.forEach((attachment) => {
        const sgid = attachment.getAttribute("sgid")
        if (sgid) attachmentBySgid.add(sgid)
        const filename = (attachment.getAttribute("filename") || "").toLowerCase()
        if (filename) attachmentByName.add(filename)
        const url = attachment.getAttribute("url") || ""
        if (url) attachmentByUrl.add(url)
      })

      container.querySelectorAll("figure.attachment").forEach((figure) => {
        let matched = false
        const dataAttr = figure.getAttribute("data-trix-attachment")
        if (dataAttr) {
          try {
            const data = JSON.parse(dataAttr)
            const sgid = data?.sgid || data?.attachable_sgid
            if (sgid && attachmentBySgid.has(sgid)) matched = true
            const name = (data?.filename || data?.name || "").toLowerCase()
            if (!matched && name && attachmentByName.has(name)) matched = true
          } catch (_error) {
            // ignore parse errors
          }
        }

        if (!matched) {
          const nameEl = figure.querySelector(".attachment__name")
          const normalizedName = nameEl?.textContent?.trim().toLowerCase()
          if (normalizedName && attachmentByName.has(normalizedName)) {
            matched = true
          }
        }

        if (!matched) {
          const img = figure.querySelector("img")
          const src = img?.getAttribute("src")
          if (src) {
            const originless = src.replace(window.location.origin, "")
            if (attachmentByUrl.has(src) || attachmentByUrl.has(originless)) {
              matched = true
            }
          }
        }

        if (matched) {
          figure.remove()
        }
      })

      const nodes = $generateNodesFromDOM(editor, container)
      let lastAttachmentPayload = null
      let removeNextBlankParagraph = false
      if (nodes.length === 0) {
        root.append($createParagraphNode())
        return
      }
      nodes.forEach((node) => {
        if (node instanceof ActionTextAttachmentNode) {
          root.append(node)
          const payload = node.getPayload?.()
          if (payload) {
            lastAttachmentPayload = {
              filename: payload.filename || "",
              filesize: Number.isFinite(payload.filesize) ? payload.filesize : null
            }
          } else {
            lastAttachmentPayload = null
          }
          removeNextBlankParagraph = true
          return
        }

        if ($isElementNode(node)) {
          if (
            removeNextBlankParagraph &&
            typeof node.getType === "function" &&
            node.getType() === "paragraph" &&
            typeof node.getChildrenSize === "function" &&
            node.getChildrenSize() === 0
          ) {
            removeNextBlankParagraph = false
            lastAttachmentPayload = null
            return
          }
          root.append(node)
          removeNextBlankParagraph = false
          lastAttachmentPayload = null
          return
        }

        if ($isTextNode(node)) {
          const paragraph = $createParagraphNode()
          paragraph.append(node)
          const textValue = paragraph.getTextContent().trim()
          if (lastAttachmentPayload) {
            const expected = new Set()
            if (lastAttachmentPayload.filename) {
              expected.add(lastAttachmentPayload.filename)
            }
            if (
              lastAttachmentPayload.filename &&
              Number.isFinite(lastAttachmentPayload.filesize)
            ) {
              expected.add(
                `${lastAttachmentPayload.filename} ${formatFileSize(lastAttachmentPayload.filesize)}`
              )
            }
            if (expected.has(textValue)) {
              lastAttachmentPayload = null
              return
            }
          }
          root.append(paragraph)
          lastAttachmentPayload = null
          removeNextBlankParagraph = !textValue
          return
        }

        const paragraph = $createParagraphNode()
        const textContent = node.getTextContent?.() || ""
        if (!textContent.trim()) {
          if (lastAttachmentPayload || removeNextBlankParagraph) {
            lastAttachmentPayload = null
            removeNextBlankParagraph = false
            return
          }
          root.append(paragraph)
          lastAttachmentPayload = null
          removeNextBlankParagraph = false
          return
        }
        const text = $createTextNode(textContent)
        paragraph.append(text)
        const textValue = paragraph.getTextContent().trim()
        if (lastAttachmentPayload) {
          const expected = new Set()
          if (lastAttachmentPayload.filename) {
            expected.add(lastAttachmentPayload.filename)
          }
          if (
            lastAttachmentPayload.filename &&
            Number.isFinite(lastAttachmentPayload.filesize)
          ) {
            expected.add(
              `${lastAttachmentPayload.filename} ${formatFileSize(lastAttachmentPayload.filesize)}`
            )
          }
          if (expected.has(textValue)) {
            lastAttachmentPayload = null
            return
          }
        }
        root.append(paragraph)
        lastAttachmentPayload = null
        removeNextBlankParagraph = false
      })

      let previousWasAttachment = false
      root.getChildren().forEach((child) => {
        if (child instanceof ActionTextAttachmentNode) {
          previousWasAttachment = true
          return
        }
        if (!previousWasAttachment) {
          previousWasAttachment = false
          return
        }
        const text = child.getTextContent?.() || ""
        if (text.trim() === "") {
          child.remove()
        }
        previousWasAttachment = false
      })

      let lastChild = root.getLastChild()
      while (
        lastChild &&
        typeof lastChild.getType === "function" &&
        lastChild.getType() === "paragraph" &&
        typeof lastChild.getChildrenSize === "function" &&
        lastChild.getChildrenSize() === 0
      ) {
        lastChild.remove()
        lastChild = root.getLastChild()
      }

      if (root.getChildrenSize() === 0) {
        root.append($createParagraphNode())
      }
    })
  }, [editor, html])

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

function Toolbar({onPromptForLink}) {
  const [editor] = useLexicalComposerContext()
  const [formats, setFormats] = useState({
    bold: false,
    italic: false,
    underline: false,
    strike: false
  })
  const imageInputRef = useRef(null)
  const fileInputRef = useRef(null)

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
    if (!$isRangeSelection(selection)) return
    setFormats({
      bold: selection.hasFormat("bold"),
      italic: selection.hasFormat("italic"),
      underline: selection.hasFormat("underline"),
      strike: selection.hasFormat("strikethrough")
    })
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

  return (
    <div className="lexical-toolbar">
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
  blobUrlTemplate
}) {
  const [editor] = useLexicalComposerContext()

  return (
    <div className="lexical-editor-shell">
      <Toolbar onPromptForLink={onPromptForLink} />
      <div className="lexical-editor-inner">
        <RichTextPlugin
          contentEditable={
            <ContentEditable
              className="lexical-content-editable"
              onKeyDown={(event) => {
                if (!onKeyDown) return
                onKeyDown(event, editor)
              }}
            />
          }
          placeholder={<Placeholder />}
          ErrorBoundary={LexicalErrorBoundary}
        />
        <HistoryPlugin />
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
  editorKey
}) {
  const initialConfig = useMemo(
    () => ({
      namespace: "CreativeLexicalEditor",
      nodes: [
        HeadingNode,
        QuoteNode,
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
      />
    </LexicalComposer>
  )
}
