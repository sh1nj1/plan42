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
import { HeadingNode, QuoteNode, $isHeadingNode, $isQuoteNode } from "@lexical/rich-text"
import {
  CodeNode,
  CodeHighlightNode,
  $isCodeNode,
  registerCodeHighlighting
} from "@lexical/code"
import { ListItemNode, ListNode, $isListItemNode, $isListNode, INSERT_ORDERED_LIST_COMMAND, INSERT_UNORDERED_LIST_COMMAND } from "@lexical/list"
import { $createLinkNode, LinkNode, AutoLinkNode } from "@lexical/link"
import { TableNode, TableRowNode, TableCellNode, INSERT_TABLE_COMMAND } from "@lexical/table"
import { TablePlugin } from "@lexical/react/LexicalTablePlugin"
import TableHoverActionsPlugin from "./plugins/table_hover_actions_plugin"
import {
  $createParagraphNode,
  $createTextNode,
  $getRoot,
  $getSelection,
  $isElementNode,
  $isLineBreakNode,
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
import { VideoNode } from "../lib/lexical/video_node"
import AttachmentCleanupPlugin from "./plugins/attachment_cleanup_plugin"
import MarkdownShortcutsPlugin from "./plugins/markdown_shortcuts_plugin"
import ListTabIndentPlugin from "./plugins/list_tab_indent_plugin"
import { syncLexicalStyleAttributes } from "../lib/lexical/style_attributes"
import { $toggleCodeBlockForSelection } from "../lib/lexical/code_block_toggle"
import { lexicalHtmlConfig, normalizeColoredContainers } from "../lib/lexical/color_import"
import { minimizeContentHtml } from "../lib/lexical/minimize_html"
import { ensureTrailingParagraph, registerTrailingParagraph } from "../lib/lexical/trailing_paragraph"
import {
  MARKDOWN_TRANSFORMERS,
  normalizeMarkdownBlankLines,
  splitBlankLineParagraphs
} from "../lib/lexical/markdown_serialize"
import { $convertToMarkdownString } from "@lexical/markdown"
import { updateResponsiveImages } from "../lib/responsive_images"
import { CODE_TOKEN_THEME } from "../lib/editor/code_token_theme"
import { detectCodeLanguage, normalizeFenceLang, bridgeCodeFenceLanguages, markLanguageResolved, isLanguageResolved, clearLanguageResolved } from "../lib/editor/code_languages"
import { CreativeLinkNode } from "../lib/lexical/creative_link_node"
import { registerCreativeLinkTrigger } from "../lib/lexical/creative_link_trigger"

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
    listitem: "lexical-list-item",
    // Tag the wrapper <li> that only holds a nested list so its bullet marker
    // can be hidden — without this Lexical reuses the plain item class and the
    // empty wrapper renders a stray bullet above the indented sub-list.
    nested: { listitem: "lexical-nested-list-item" }
  },
  code: "lexical-code-block",
  codeHighlight: CODE_TOKEN_THEME,
  link: "lexical-link",
  text: {
    bold: "lexical-text-bold",
    italic: "lexical-text-italic",
    underline: "lexical-text-underline",
    strikethrough: "lexical-text-strike",
    code: "lexical-text-code"
  },
  table: "lexical-table",
  tableScrollableWrapper: "lexical-table-wrapper",
  tableRow: "lexical-table-row",
  tableCell: "lexical-table-cell",
  tableCellHeader: "lexical-table-cell-header",
  tableSelected: "lexical-table-selected",
  tableSelection: "lexical-table-selection",
  tableAddRows: "lexical-table-add-rows",
  tableAddColumns: "lexical-table-add-columns",
  tableDeleteRows: "lexical-table-delete-rows",
  tableDeleteColumns: "lexical-table-delete-columns"
}

function Placeholder({ text }) {
  const fallback = "Describe the creative…"
  return <div className="lexical-placeholder">{text || fallback}</div>
}

function InitialContentPlugin({ html }) {
  const [editor] = useLexicalComposerContext()
  const lastApplied = useRef(null)

  useEffect(() => {
    if (lastApplied.current === html) return
    lastApplied.current = html
    editor.update(() => {
      const root = $getRoot()
      // Re-importing replaces the tree; drop stale resolved-language keys so the
      // registry only tracks nodes from this import.
      clearLanguageResolved(editor)
      // Explicitly remove all children to ensure it's empty
      root.getChildren().forEach((child) => child.remove())

      const parser = new DOMParser()
      const doc = parser.parseFromString(html || "", "text/html")
      // No more .trix-content wrapper
      const container = doc.body

      // @lexical/code's importer only reads `data-language`, but the language is
      // encoded differently depending on which renderer produced this HTML:
      // commonmarker (server reopen) uses `<pre lang>`, while renderMarkdown (the
      // markdown→rich toggle) puts it on `<pre><code class="language-X">`. Bridge
      // both onto `data-language` so an explicit fence language survives reopen
      // instead of being dropped (and then defaulted to javascript). Detection
      // still corrects unlabeled blocks.
      bridgeCodeFenceLanguages(container)

      // Color / background-color are bound to text nodes during import by the
      // colorAwareSpanImport html config (see lib/lexical/color_import). We no
      // longer re-apply styles positionally after import, which used to drift
      // onto the wrong text node whenever Lexical split or dropped text nodes.
      syncLexicalStyleAttributes(container)
      // Push color/background-color from non-span elements onto spans so the
      // colorAwareSpanImport config binds it (the span importer can't see it
      // otherwise). Must run after the sync above materializes data-lexical-*.
      normalizeColoredContainers(container)
      const nodes = $generateNodesFromDOM(editor, container)

      // Mark code blocks whose language came from an explicit source label as
      // resolved BEFORE registerCodeHighlighting bakes the "javascript" default
      // onto unlabeled ones. At this point a non-empty language can only be one
      // the bridge set from a real fence/attribute, so the detection transform
      // will honor it verbatim (incl. an explicit "javascript") and only
      // re-detect the still-unlabeled blocks.
      const markExplicitCodeLanguages = (list) => {
        list.forEach((node) => {
          if ($isCodeNode(node)) {
            if (node.getLanguage()) markLanguageResolved(editor, node.getKey())
          } else if ($isElementNode(node) && typeof node.getChildren === "function") {
            markExplicitCodeLanguages(node.getChildren())
          }
        })
      }
      markExplicitCodeLanguages(nodes)

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
      // Text nodes and inline elements (links, etc.) cannot live directly under
      // the root. Minimized HTML stores a single line without its <p> wrapper, so
      // a line like "Hello <strong>World</strong>" re-imports as several
      // top-level inline nodes — group consecutive ones back into one paragraph
      // so the line is not split apart.
      let pendingParagraph = null
      const flushPending = () => {
        if (pendingParagraph) {
          root.append(pendingParagraph)
          appendedNodes.push(pendingParagraph)
          pendingParagraph = null
        }
      }
      uniqueNodes.forEach((node) => {
        const isInlineLeaf =
          $isTextNode(node) ||
          $isLineBreakNode(node) ||
          ($isElementNode(node) && node.isInline())
        if (isInlineLeaf) {
          if (!pendingParagraph) pendingParagraph = $createParagraphNode()
          pendingParagraph.append(node)
          return
        }

        flushPending()
        root.append(node)
        appendedNodes.push(node)
      })
      flushPending()

      if (root.getChildrenSize() === 0) {
        const paragraph = $createParagraphNode()
        root.append(paragraph)
        appendedNodes.push(paragraph)
      }

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

      // A blank line the user typed is an empty paragraph, but the server renders
      // it as a standalone <br> that re-imports as a paragraph holding a
      // LineBreakNode — which Lexical draws as TWO lines, so blank lines grew by
      // one on every reopen. Split those marker paragraphs back into empty
      // paragraphs so reopened blank lines match freshly typed ones. Runs AFTER
      // the trailing-empty cleanup above so an intentional trailing blank line
      // (a marker paragraph the cleanup leaves alone) is preserved, not stripped.
      splitBlankLineParagraphs(root)

      // A trailing top-level image/video/attachment leaves no caret position
      // after it, making the document uneditable. Guarantee an editable
      // paragraph after it. (The RootNode transform below keeps this true while
      // editing; this handles the initial load deterministically regardless of
      // plugin effect ordering.)
      ensureTrailingParagraph(root)
    })
  }, [editor, html])

  return null
}

function TrailingParagraphPlugin() {
  const [editor] = useLexicalComposerContext()
  useEffect(() => registerTrailingParagraph(editor), [editor])
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

function CreativeLinkTriggerPlugin() {
  const [editor] = useLexicalComposerContext()

  useEffect(() => registerCreativeLinkTrigger(editor, ({ anchorRect, onSelect, onClose }) => {
    const modal = document.getElementById("link-creative-modal")
    const controller = modal && window.Stimulus?.getControllerForElementAndIdentifier(
      modal,
      "link-creative"
    )
    if (!controller) return false

    controller.open(anchorRect, onSelect, onClose, { allowCreate: true })
    return true
  }), [editor])

  return null
}

function CodeHighlightingPlugin() {
  const [editor] = useLexicalComposerContext()

  useEffect(() => {
    const unregisterHighlight = registerCodeHighlighting(editor)

    // registerCodeHighlighting bakes "javascript" onto any code block without a
    // language (its tokenizer default), which then serializes into the canonical
    // markdown as ```javascript — so Ruby/Python/etc. blocks get permanently
    // mislabeled on the first edit. This transform re-detects the real language
    // from the block's content whenever it's unconfirmed (missing or stuck on
    // the javascript default) and corrects the node, so the editor shows — and
    // saves — the right language. An explicit non-default language is left alone.
    const unregisterDetect = editor.registerNodeTransform(CodeNode, (node) => {
      // A language that came from an explicit source label on import is honored
      // verbatim — including "javascript" — so auto-detection never overrides a
      // deliberate choice. Only unlabeled/new blocks (baked to the javascript
      // default) are re-detected from their content.
      if (isLanguageResolved(editor, node.getKey())) return
      const current = node.getLanguage()
      const norm = normalizeFenceLang(current)
      if (norm && norm !== "javascript") return
      const detected = detectCodeLanguage(node.getTextContent(), current)
      if (detected && detected !== "javascript" && detected !== current) {
        node.setLanguage(detected)
      }
    })

    return () => {
      unregisterHighlight()
      unregisterDetect()
    }
  }, [editor])

  return null
}

const EDITOR_TEXT_TOKENS = [
  { token: "var(--text-primary)", label: "Primary" },
  { token: "var(--text-muted)", label: "Muted" },
  { token: "var(--color-danger)", label: "Danger" },
  { token: "var(--color-warning)", label: "Warning" },
  { token: "var(--color-brand)", label: "Brand" },
  { token: "var(--color-link)", label: "Link" },
  { token: "var(--color-accent-text)", label: "Accent" },
  { token: "var(--color-code-text)", label: "Code" }
]

const EDITOR_BG_TOKENS = [
  { token: "var(--surface-bg)", label: "Background" },
  { token: "var(--color-highlight)", label: "Highlight" },
  { token: "var(--color-brand)", label: "Brand" },
  { token: "var(--color-accent-border)", label: "Accent" },
  { token: "var(--color-danger)", label: "Danger" },
  { token: "var(--color-warning)", label: "Warning" },
  { token: "var(--color-code-bg)", label: "Code" },
  { token: "var(--surface-hover)", label: "Hover" }
]

function resolveColorForInput(color) {
  if (!color || !color.startsWith("var(")) return color
  const match = color.match(/^var\(([^)]+)\)$/)
  if (!match) return color
  return getComputedStyle(document.documentElement).getPropertyValue(match[1]).trim() || color
}

function ToolbarColorPicker({ icon, title, color, onChange, onClear, colorType }) {
  const [open, setOpen] = useState(false)
  const triggerRef = useRef(null)
  const popoverRef = useRef(null)
  const tokens = colorType === "background" ? EDITOR_BG_TOKENS : EDITOR_TEXT_TOKENS

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

  const resolvedColor = resolveColorForInput(color)

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
          <div className="lexical-toolbar-color__tokens">
            {tokens.map(({ token, label }) => (
              <button
                key={token}
                type="button"
                className={`lexical-toolbar-color__token-btn${color === token ? " active" : ""}`}
                style={{ backgroundColor: token }}
                title={label}
                onClick={() => {
                  onChange(token)
                  setOpen(false)
                }}
              />
            ))}
          </div>
          <div className="lexical-toolbar-color__custom-row">
            <input
              type="color"
              value={resolvedColor.startsWith("#") ? resolvedColor : "#000000"}
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
        </div>
      ) : null}
    </div>
  )
}


import LinkPopup from "./LinkPopup"

function Toolbar() {
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

  const insertTable = useCallback(() => {
    editor.dispatchCommand(INSERT_TABLE_COMMAND, {
      columns: "3",
      rows: "3",
      includeHeaders: true
    })
  }, [editor])

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

  const clearFormatting = useCallback(() => {
    editor.update(() => {
      const selection = $getSelection()
      if (!$isRangeSelection(selection)) return

      // 1. Clear inline text formats and styles
      const extractedNodes = selection.extract()
      extractedNodes.forEach((node) => {
        if ($isTextNode(node)) {
          node.setFormat(0)
          node.setStyle("")
        }
      })

      // 2. Convert block-level nodes (headings, quotes, code, lists) to paragraphs
      const nodes = selection.getNodes()
      const visited = new Set()
      nodes.forEach((node) => {
        const topLevel = node.getTopLevelElement()
        if (!topLevel || visited.has(topLevel.getKey())) return
        visited.add(topLevel.getKey())

        if ($isHeadingNode(topLevel) || $isQuoteNode(topLevel)) {
          // Replace heading/quote with paragraph preserving children
          const paragraph = $createParagraphNode()
          topLevel.getChildren().forEach((child) => paragraph.append(child))
          topLevel.replace(paragraph)
        } else if ($isCodeNode(topLevel)) {
          // Convert code block to paragraphs (one per line)
          const textContent = topLevel.getTextContent()
          const lines = textContent.split("\n")
          const firstParagraph = $createParagraphNode()
          firstParagraph.append($createTextNode(lines[0] || ""))
          topLevel.replace(firstParagraph)
          let previous = firstParagraph
          for (let i = 1; i < lines.length; i++) {
            const p = $createParagraphNode()
            p.append($createTextNode(lines[i]))
            previous.insertAfter(p)
            previous = p
          }
        } else if ($isListNode(topLevel)) {
          // Replace list with paragraphs for each list item
          const items = topLevel.getChildren()
          const paragraphs = []
          items.forEach((item) => {
            const p = $createParagraphNode()
            if ($isListItemNode(item)) {
              item.getChildren().forEach((child) => {
                if ($isListNode(child)) {
                  // Nested list — flatten text content
                  p.append($createTextNode(child.getTextContent()))
                } else {
                  p.append(child)
                }
              })
            } else {
              p.append($createTextNode(item.getTextContent()))
            }
            paragraphs.push(p)
          })
          if (paragraphs.length > 0) {
            topLevel.replace(paragraphs[0])
            let prev = paragraphs[0]
            for (let i = 1; i < paragraphs.length; i++) {
              prev.insertAfter(paragraphs[i])
              prev = paragraphs[i]
            }
          }
        }
      })

      setFontColor(DEFAULT_FONT_COLOR)
      setBgColor(DEFAULT_BG_COLOR)
    })
  }, [editor])

  const toggleCodeBlock = useCallback(() => {
    editor.update(() => {
      $toggleCodeBlockForSelection()
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
        className="lexical-toolbar-btn"
        onClick={clearFormatting}
        title="Clear formatting">
        Tₓ
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
      <button
        type="button"
        className="lexical-toolbar-btn"
        onClick={insertTable}
        title="Insert table"
        aria-label="Insert table">
        ▦
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
        colorType="text"
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
        colorType="background"
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
  onEnterKey,
  onReady,
  onUploadStateChange,
  directUploadUrl,
  blobUrlTemplate,
  placeholderText,
  deletedAttachmentsRef
}) {
  const [editor] = useLexicalComposerContext()

  // Anchor for the floating table plugins (hover "+" and the cell action menu).
  // Portaling into the editor's own subtree (not document.body) ties the floating
  // UI's lifetime to the editor DOM: when the editor is torn down — including
  // Turbo/host teardown that removes the container without a React unmount — the
  // chevron button is removed with it instead of being orphaned in document.body.
  const [floatingAnchorElem, setFloatingAnchorElem] = useState(null)
  const onAnchorRef = useCallback((el) => {
    if (el !== null) setFloatingAnchorElem(el)
  }, [])

  // File drop is handled by FileUploadPlugin's DROP_COMMAND handler.
  // We only need dragOver to allow the browser to accept file drops.
  const handleDragOver = useCallback((event) => {
    if (event.dataTransfer?.types?.includes("Files")) {
      event.preventDefault()
    }
  }, [])

  return (
    <div className="lexical-editor-shell">
      <Toolbar />
      <div className="lexical-editor-inner" ref={onAnchorRef}>
        <RichTextPlugin
          contentEditable={
            <ContentEditable
              className="lexical-content-editable shared-input-surface"
              onKeyDown={(event) => {
                if (!onKeyDown) return
                onKeyDown(event, editor)
              }}
              onDragOver={handleDragOver}
            />
          }
          placeholder={<Placeholder text={placeholderText} />}
          ErrorBoundary={LexicalErrorBoundary}
        />
        <HistoryPlugin />
        <CodeHighlightingPlugin />
        <ListPlugin />
        <TablePlugin hasCellMerge={false} hasCellBackgroundColor={false} />
        {floatingAnchorElem && (
          <TableHoverActionsPlugin anchorElem={floatingAnchorElem} />
        )}
        <ListTabIndentPlugin />
        <LinkPlugin />
        <AutoLinkPlugin matchers={URL_MATCHERS} />
        <OnChangePlugin
          onChange={(editorState, editorInstance) => {
            if (!onChange) return
            let serialized = ""
            let markdown = ""
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
              // Strip Lexical's verbose markup (extra <div>, white-space spans,
              // duplicate format wrappers, single-line <p>) before persisting.
              serialized = minimizeContentHtml(doc.body.firstElementChild)
              // Canonical Markdown projection (color/bg -> normalized <span>).
              // normalizeMarkdownBlankLines keeps the standard `\n\n` paragraph
              // separation (Enter = real paragraph break) and only tidies blank-
              // line runs / the empty-state — no marker characters in the source.
              markdown = normalizeMarkdownBlankLines($convertToMarkdownString(MARKDOWN_TRANSFORMERS))
            })
            // html: client-side preview/fallback; markdown: canonical storage.
            onChange({ html: serialized, markdown })
          }}
        />
        <TrailingParagraphPlugin />
        <InitialContentPlugin html={initialHtml} />
        <LinkAttributesPlugin />
        <CreativeLinkTriggerPlugin />
        <ReadyPlugin onReady={onReady} />
        <FileUploadPlugin
          onUploadStateChange={onUploadStateChange}
          directUploadUrl={directUploadUrl}
          blobUrlTemplate={blobUrlTemplate}
        />
        <AttachmentCleanupPlugin deletedAttachmentsRef={deletedAttachmentsRef} />
        <MarkdownShortcutsPlugin />
        {onEnterKey && <EnterKeyPlugin onEnterKey={onEnterKey} />}
      </div>
    </div>
  )
}

function EnterKeyPlugin({ onEnterKey }) {
  const [editor] = useLexicalComposerContext()

  useEffect(() => {
    // Use capture-phase keydown on the root element to intercept Shift+Enter
    // BEFORE Lexical's own handlers process it.
    // Bare Enter is left to Lexical for newline insertion.
    const rootElement = editor.getRootElement()
    if (!rootElement) return

    const handler = (event) => {
      if (event.key !== 'Enter') return
      if (!event.shiftKey) return // only intercept Shift+Enter
      if (event.altKey || event.ctrlKey || event.metaKey) return
      if (event.isComposing) return

      if (onEnterKey(event, editor) === true) {
        event.preventDefault()
        event.stopImmediatePropagation()
      }
    }

    rootElement.addEventListener('keydown', handler, true) // capture phase
    return () => rootElement.removeEventListener('keydown', handler, true)
  }, [editor, onEnterKey])

  return null
}

export default function InlineLexicalEditor({
  initialHtml,
  onChange,
  onKeyDown,
  onEnterKey,
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
        CreativeLinkNode,
        ImageNode,
        AttachmentNode,
        VideoNode,
        TableNode,
        TableRowNode,
        TableCellNode
      ],
      onError(error) {
        throw error
      },
      theme,
      html: lexicalHtmlConfig
    }),
    []
  )

  return (
    <LexicalComposer key={editorKey} initialConfig={initialConfig}>
      <EditorInner
        initialHtml={initialHtml}
        onChange={onChange}
        onKeyDown={onKeyDown}
        onEnterKey={onEnterKey}
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
