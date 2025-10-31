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
  $getRoot,
  $getSelection,
  $isRangeSelection,
  COMMAND_PRIORITY_LOW,
  FORMAT_TEXT_COMMAND,
  SELECTION_CHANGE_COMMAND
} from "lexical"
import {$generateHtmlFromNodes, $generateNodesFromDOM} from "@lexical/html"
import {useLexicalComposerContext} from "@lexical/react/LexicalComposerContext"

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
      const nodes = $generateNodesFromDOM(editor, container)
      if (nodes.length === 0) {
        root.append($createParagraphNode())
        return
      }
      nodes.forEach((node) => {
        root.append(node)
      })
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

function EditorInner({initialHtml, onChange, onKeyDown, onPromptForLink, onReady}) {
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
  editorKey
}) {
  const initialConfig = useMemo(
    () => ({
      namespace: "CreativeLexicalEditor",
      nodes: [HeadingNode, QuoteNode, ListItemNode, ListNode, LinkNode, AutoLinkNode],
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
      />
    </LexicalComposer>
  )
}
