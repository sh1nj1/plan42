import { createRoot } from "react-dom/client"
import InlineLexicalEditor from "./components/InlineLexicalEditor"

const DEFAULT_KEY = "creative-inline-editor"

export function createInlineEditor(container, {
  onChange,
  onKeyDown,
  onPromptForLink,
  onUploadStateChange
} = {}) {
  if (!container) {
    throw new Error("Lexical editor container not found")
  }

  const root = createRoot(container)
  let suppressNextChange = false
  let focusHandler = () => { }
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
        onPromptForLink={onPromptForLink ?? promptForLink}
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

function promptForLink() {
  const value = window.prompt("Enter a URL")
  if (!value) return null
  try {
    const url = new URL(value, window.location.origin)
    return url.toString()
  } catch (_error) {
    return value.trim() || null
  }
}
