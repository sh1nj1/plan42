import { createRoot } from "react-dom/client"
import { $getRoot } from "lexical"
import InlineLexicalEditor from "../components/InlineLexicalEditor"

const DEFAULT_KEY = "creative-inline-editor"

export function createInlineEditor(container, {
  onChange,
  onKeyDown,

  onUploadStateChange
} = {}) {
  if (!container) {
    throw new Error("Lexical editor container not found")
  }

  const root = createRoot(container)
  let suppressNextChange = false
  let focusHandler = () => { }
  let editorInstance = null
  let editorReady = false
  let pendingFocus = false
  let currentKey = DEFAULT_KEY
  let currentHtml = ""
  const directUploadUrl = container.dataset.directUploadUrl || null
  const blobUrlTemplate = container.dataset.blobUrlTemplate || null
  const placeholderText = container.dataset.placeholder || null

  const deletedAttachmentsRef = { current: [] }

  function render(html, key = currentKey) {
    currentKey = key
    currentHtml = html ?? ""
    suppressNextChange = true
    editorReady = false
    deletedAttachmentsRef.current = []
    if (container.dataset) {
      container.dataset.editorReady = "false"
    }
    root.render(
      <InlineLexicalEditor
        initialHtml={currentHtml}
        editorKey={currentKey}
        placeholderText={placeholderText}
        // onPromptForLink removed
        onKeyDown={(event, editor) => {
          if (onKeyDown) onKeyDown(event, editor)
        }}
        onChange={(value) => {
          if (suppressNextChange) {
            suppressNextChange = false
            return
          }
          currentHtml = value
          onChange?.(value)
        }}
        onReady={(api) => {
          focusHandler = api?.focus ?? (() => { })
          editorInstance = api?.getEditor?.()
          editorReady = true
          if (container.dataset) {
            container.dataset.editorReady = "true"
          }
          if (pendingFocus) {
            requestAnimationFrame(() => {
              focusHandler()
              pendingFocus = false
            })
          }
        }}
        onUploadStateChange={onUploadStateChange}
        directUploadUrl={directUploadUrl}
        blobUrlTemplate={blobUrlTemplate}
        deletedAttachmentsRef={deletedAttachmentsRef}
      />
    )
  }

  render("")

  return {
    load(html, key) {
      render(html ?? "", key)
    },
    reset(key) {
      render("", key)
    },
    focus() {
      pendingFocus = true
      if (editorReady) {
        requestAnimationFrame(() => {
          focusHandler()
          pendingFocus = false
        })
      }
    },
    focusAtStart() {
      pendingFocus = true
      if (editorReady && editorInstance) {
        editorInstance.update(() => {
          const root = $getRoot()
          const firstChild = root.getFirstChild()
          if (firstChild) {
            if (firstChild.selectStart) {
              firstChild.selectStart()
            } else {
              root.selectStart()
            }
          } else {
            root.selectStart()
          }
        })
        requestAnimationFrame(() => {
          focusHandler()
          pendingFocus = false
        })
      }
    },
    destroy() {
      if (container.dataset) {
        delete container.dataset.editorReady
      }
      root.unmount()
    },
    getDeletedAttachments() {
      const ids = Array.from(deletedAttachmentsRef.current || [])
      deletedAttachmentsRef.current = []
      return ids
    }
  }
}


