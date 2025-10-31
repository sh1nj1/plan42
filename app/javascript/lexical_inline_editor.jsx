import {createRoot} from "react-dom/client"
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
  let focusHandler = () => {}
  let editorReady = false
  let pendingFocus = false
  let currentKey = DEFAULT_KEY
  let currentHtml = ""
  const directUploadUrl = container.dataset.directUploadUrl || null
  const blobUrlTemplate = container.dataset.blobUrlTemplate || null

  function render(html, key = currentKey) {
    currentKey = key
    currentHtml = html ?? ""
    suppressNextChange = true
    editorReady = false
    root.render(
      <InlineLexicalEditor
        initialHtml={currentHtml}
        editorKey={currentKey}
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
          focusHandler = api?.focus ?? (() => {})
          editorReady = true
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
      root.unmount()
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
