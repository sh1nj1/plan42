import { useCallback, useEffect, useMemo, useRef, useState } from "react"
import { LexicalComposer } from "@lexical/react/LexicalComposer"
import { RichTextPlugin } from "@lexical/react/LexicalRichTextPlugin"
import { ContentEditable } from "@lexical/react/LexicalContentEditable"
import { HistoryPlugin } from "@lexical/react/LexicalHistoryPlugin"
import { OnChangePlugin } from "@lexical/react/LexicalOnChangePlugin"
import { ListPlugin } from "@lexical/react/LexicalListPlugin"
import { LinkPlugin } from "@lexical/react/LexicalLinkPlugin"
import {
  AutoLinkPlugin,
  createLinkMatcherWithRegExp
} from "@lexical/react/LexicalAutoLinkPlugin"
import { LexicalErrorBoundary } from "@lexical/react/LexicalErrorBoundary"
import { HeadingNode, QuoteNode } from "@lexical/rich-text"
import {
  CodeNode,
  CodeHighlightNode,
  $createCodeNode,
  $isCodeNode,
  registerCodeHighlighting
} from "@lexical/code"
import { ListItemNode, ListNode, INSERT_ORDERED_LIST_COMMAND, INSERT_UNORDERED_LIST_COMMAND } from "@lexical/list"
import { $createLinkNode, LinkNode, AutoLinkNode, TOGGLE_LINK_COMMAND } from "@lexical/link"
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
import { $patchStyleText } from "@lexical/selection"
import { $generateHtmlFromNodes, $generateNodesFromDOM } from "@lexical/html"
import { useLexicalComposerContext } from "@lexical/react/LexicalComposerContext"
import FileUploadPlugin, {
  INSERT_IMAGE_COMMAND,
  INSERT_FILE_COMMAND
} from "./plugins/image_upload_plugin"
import { ImageNode } from "../lib/lexical/image_node"
import { AttachmentNode } from "../lib/lexical/attachment_node"
import AttachmentCleanupPlugin from "./plugins/attachment_cleanup_plugin"
import { syncLexicalStyleAttributes } from "../lib/lexical/style_attributes"
import { updateResponsiveImages } from "../lib/responsive_images"

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

function Placeholder({ text }) {
  const fallback = "Describe the creative…"
  return <div className="lexical-placeholder">{text || fallback}</div>
}

function InitialContentPlugin({ html }) {
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
      // Explicitly remove all children to ensure it's empty
      root.getChildren().forEach((child) => child.remove())

      const parser = new DOMParser()
      const doc = parser.parseFromString(html || "", "text/html")
      // No more .trix-content wrapper
      const container = doc.body

      syncLexicalStyleAttributes(container)
      const collectedStyles = collectDomTextStyles(container)
      const nodes = $generateNodesFromDOM(editor, container)

      // Filter out duplicate image nodes if any
      const uniqueNodes = []
      const seenImages = new Set()

      nodes.forEach(node => {
        // Check if the node is an ImageNode and if it has a getSrc method
        if (node.getType() === 'image' && typeof node.getSrc === 'function') {
          const src = node.getSrc()
          if (!seenImages.has(src)) {
            seenImages.add(src)
            uniqueNodes.push(node)
          }
        } else {
          uniqueNodes.push(node)
        }
      })

      const appendedNodes = []
      uniqueNodes.forEach((node) => {
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

function ToolbarColorPicker({ icon, title, color, onChange, onClear }) {
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
        <span className="lexical-toolbar-color__swatch" style={{ backgroundColor: color }} />
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


function LinkPopup({ initialLabel, initialUrl, onConfirm, onCancel }) {
  const [label, setLabel] = useState(initialLabel || "")
  const [url, setUrl] = useState(initialUrl || "")

  useEffect(() => {
    setLabel(initialLabel || "")
    setUrl(initialUrl || "")
  }, [initialLabel, initialUrl])

  const handleKeyDown = (e) => {
    if (e.key === "Enter") {
      e.preventDefault()
      onConfirm(label, url)
    } else if (e.key === "Escape") {
      e.preventDefault()
      e.stopPropagation()
      onCancel()
    }
  }

  return (
    <div
      className="lexical-link-popup stacked-form"
      style={{
        position: "absolute",
        top: "40px",
        right: "0",
        zIndex: 100,
        backgroundColor: "var(--color-bg)",
        padding: "1rem",
        borderRadius: "8px",
        boxShadow: "0 4px 12px rgba(0,0,0,0.15)",
        border: "1px solid var(--color-border)",
        minWidth: "260px"
      }}>
      <div>
        <label style={{ display: "block", fontSize: "0.8em", fontWeight: "bold", marginBottom: "0.25rem", color: "var(--color-text)" }}>Label</label>
        <input
          type="text"
          placeholder="Link text"
          value={label}
          onChange={(e) => setLabel(e.target.value)}
          onKeyDown={handleKeyDown}
          style={{ width: "100%", boxSizing: "border-box" }}
        />
      </div>
      <div>
        <label style={{ display: "block", fontSize: "0.8em", fontWeight: "bold", marginBottom: "0.25rem", color: "var(--color-text)" }}>URL</label>
        <input
          type="text"
          placeholder="https://example.com"
          value={url}
          onChange={(e) => setUrl(e.target.value)}
          onKeyDown={handleKeyDown}
          style={{ width: "100%", boxSizing: "border-box" }}
        />
      </div>
      <div style={{ display: "flex", justifyContent: "flex-end", gap: "0.5rem", marginTop: "0.5rem" }}>
        <button
          type="button"
          onClick={onCancel}
          style={{
            background: "none",
            border: "none",
            cursor: "pointer",
            color: "var(--color-text)",
            padding: "0.45em 0.9em",
            fontSize: "0.9rem"
          }}>
          Cancel
        </button>
        <button
          type="button"
          className="primary-action-button"
          onClick={() => onConfirm(label, url)}>
          Confirm
        </button>
      </div>
    </div>
  )
}

function Toolbar({ onPromptForLink }) {
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
  const [showLinkPopup, setShowLinkPopup] = useState(false)
  const [linkPopupData, setLinkPopupData] = useState({ label: "", url: "" })

  const handleFiles = useCallback(
    (fileList, options = {}) => {
      if (!fileList) return
      Array.from(fileList).forEach((file) => {
        if (file) {
          // Use INSERT_FILE_COMMAND which handles both images and files
          editor.dispatchCommand(INSERT_FILE_COMMAND, {
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
    return editor.registerUpdateListener(({ editorState }) => {
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
    let hasLink = false
    let selectionText = ""
    let isRange = false
    let url = ""

    editor.getEditorState().read(() => {
      const selection = $getSelection()
      if (!$isRangeSelection(selection)) return

      isRange = true
      selectionText = selection.getTextContent()

      const nodes = selection.getNodes()
      const nodeWithLink = nodes.find((node) => {
        if (node.getType() === "link") return true
        const parent = node.getParent()
        return parent?.getType() === "link"
      })

      if (nodeWithLink) {
        hasLink = true
        const linkNode = nodeWithLink.getType() === "link" ? nodeWithLink : nodeWithLink.getParent()
        url = linkNode.getURL()
      }
    })

    if (!isRange) return

    setLinkPopupData({ label: selectionText, url: url })
    setShowLinkPopup(true)
  }, [editor])

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
          applyTextStyle({ color: value })
        }}
        onClear={() => {
          setFontColor(DEFAULT_FONT_COLOR)
          applyTextStyle({ color: "" })
        }}
      />
      <ToolbarColorPicker
        icon="🖌️"
        title="Background color"
        color={bgColor}
        onChange={(value) => {
          setBgColor(value)
          applyTextStyle({ "background-color": value })
        }}
        onClear={() => {
          setBgColor(DEFAULT_BG_COLOR)
          applyTextStyle({ "background-color": "" })
        }}
      />
      <span className="lexical-toolbar-separator" aria-hidden="true" />
      <input
        ref={imageInputRef}
        type="file"
        accept="image/*"
        style={{ display: "none" }}
        onChange={(event) => {
          handleFiles(event.target.files, { kind: "image" })
          event.target.value = ""
        }}
      />
      <input
        ref={fileInputRef}
        type="file"
        style={{ display: "none" }}
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
      {showLinkPopup && (
        <LinkPopup
          initialLabel={linkPopupData.label}
          initialUrl={linkPopupData.url}
          onConfirm={(label, url) => {
            const finalUrl = url?.trim()
            if (!finalUrl) {
              setShowLinkPopup(false)
              return
            }
            const finalLabel = (label || "").trim() || finalUrl

            editor.update(() => {
              const selection = $getSelection()
              if (!selection) return

              // Check if we are editing an existing link
              const nodes = selection.getNodes()
              const nodeWithLink = nodes.find((node) => {
                if (node.getType() === "link") return true
                const parent = node.getParent()
                return parent?.getType() === "link"
              })

              if (nodeWithLink) {
                // UPDATE MODE
                const linkNode = nodeWithLink.getType() === "link" ? nodeWithLink : nodeWithLink.getParent()
                const newLink = $createLinkNode(finalUrl)
                newLink.append($createTextNode(finalLabel))
                linkNode.replace(newLink)
                newLink.select()
              } else {
                // CREATE MODE
                const newLink = $createLinkNode(finalUrl)
                newLink.append($createTextNode(finalLabel))

                if ($isRangeSelection(selection) && !selection.isCollapsed()) {
                  // Replace selection
                  selection.insertNodes([newLink])
                } else {
                  // Insert at cursor
                  selection.insertNodes([newLink])
                }
                // Explicitly select the new link to ensure selection validity
                newLink.select()
              }
            })

            setShowLinkPopup(false)
          }}
          onCancel={() => setShowLinkPopup(false)}
        />
      )}
    </div>
  )
}

function ReadyPlugin({ onReady }) {
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
  placeholderText,
  deletedAttachmentsRef
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

              const rootElement = editorInstance.getRootElement()

              syncLexicalStyleAttributes(doc.body)
              updateResponsiveImages(doc.body, rootElement?.clientWidth)

              doc.querySelectorAll("a").forEach((anchor) => {
                anchor.setAttribute("target", "_blank")
                anchor.setAttribute("rel", "noopener")
              })
              serialized = doc.body.innerHTML
            })
            // No Trix wrapper
            onChange(serialized)
          }}
        />
        <InitialContentPlugin html={initialHtml} />
        <LinkAttributesPlugin />
        <ReadyPlugin onReady={onReady} />
        <FileUploadPlugin
          onUploadStateChange={onUploadStateChange}
          directUploadUrl={directUploadUrl}
          blobUrlTemplate={blobUrlTemplate}
        />
        <AttachmentCleanupPlugin deletedAttachmentsRef={deletedAttachmentsRef} />
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
  placeholderText,
  deletedAttachmentsRef
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
        ImageNode,
        AttachmentNode
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
        deletedAttachmentsRef={deletedAttachmentsRef}
      />
    </LexicalComposer>
  )
}
