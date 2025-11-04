import {useEffect, useCallback, useRef} from "react"
import {DirectUpload as ModuleDirectUpload} from "@rails/activestorage"
import {useLexicalComposerContext} from "@lexical/react/LexicalComposerContext"
import {mergeRegister} from "@lexical/utils"
import {
  $createParagraphNode,
  $getNodeByKey,
  $getRoot,
  $getSelection,
  $isRangeSelection,
  COMMAND_PRIORITY_EDITOR,
  DROP_COMMAND,
  PASTE_COMMAND,
  createCommand
} from "lexical"

import {
  $createActionTextAttachmentNode,
  $isActionTextAttachmentNode
} from "../../lib/lexical/action_text_attachment_node"
import {
  sanitizeAttachmentPayload
} from "../../lib/lexical/attachment_payload"

export const INSERT_ACTIONTEXT_ATTACHMENT_COMMAND = createCommand("INSERT_ACTIONTEXT_ATTACHMENT_COMMAND")

function isImageFile(file) {
  if (!file) return false
  if (file.type) return /^image\//i.test(file.type)
  return /\.(bmp|gif|jpe?g|png|svg|webp)$/i.test(file.name || "")
}

function readImageDimensions(url) {
  return new Promise((resolve) => {
    const img = new Image()
    img.onload = () => {
      resolve({
        width: img.naturalWidth || null,
        height: img.naturalHeight || null
      })
    }
    img.onerror = () => resolve({width: null, height: null})
    img.src = url
  })
}

function readFileAsDataUrl(file) {
  return new Promise((resolve) => {
    const reader = new FileReader()
    reader.onload = () => {
      resolve(typeof reader.result === "string" ? reader.result : null)
    }
    reader.onerror = () => resolve(null)
    reader.readAsDataURL(file)
  })
}

export default function ActionTextAttachmentPlugin({
  onUploadStateChange,
  directUploadUrl,
  blobUrlTemplate
}) {
  const [editor] = useLexicalComposerContext()
  const pendingUploadsRef = useRef(0)

  const notifyUploadState = useCallback(() => {
    if (onUploadStateChange) {
      onUploadStateChange(pendingUploadsRef.current > 0, pendingUploadsRef.current)
    }
  }, [onUploadStateChange])

  useEffect(() => {
    notifyUploadState()
  }, [notifyUploadState])

  const incrementUploads = useCallback(() => {
    pendingUploadsRef.current += 1
    notifyUploadState()
  }, [notifyUploadState])

  const decrementUploads = useCallback(() => {
    pendingUploadsRef.current = Math.max(0, pendingUploadsRef.current - 1)
    notifyUploadState()
  }, [notifyUploadState])

  const startDirectUpload = useCallback(
    (file, options = {}) => {
      if (!file) return
      const previewable = options.kind === "image" ? true : isImageFile(file)
      const previewPromise = previewable ? readFileAsDataUrl(file) : Promise.resolve(null)

      editor.update(() => {
        const node = $createActionTextAttachmentNode(
          sanitizeAttachmentPayload({
            status: "uploading",
            filename: file.name,
            contentType: file.type,
            filesize: file.size,
            previewable
          })
        )
        const selection = $getSelection()
        if ($isRangeSelection(selection)) {
          selection.insertNodes([node])
          const paragraph = $createParagraphNode()
          node.insertAfter(paragraph)
          paragraph.selectStart()
        } else {
          const root = $getRoot()
          root.append(node)
          const paragraph = $createParagraphNode()
          root.append(paragraph)
          paragraph.selectStart()
        }
        const nodeKey = node.getKey()

        Promise.resolve().then(() => {
          if (!nodeKey) return

          editor.update(() => {
            const currentNode = $getNodeByKey(nodeKey)
            if ($isActionTextAttachmentNode(currentNode)) {
              const existing = currentNode.getPayload()
              currentNode.markUploading(
                sanitizeAttachmentPayload({
                  ...existing,
                  filename: file.name,
                  contentType: file.type || existing.contentType,
                  filesize: file.size ?? existing.filesize,
                  previewable: previewable || existing.previewable,
                  localUrl: previewable ? existing.localUrl : null
                })
              )
            }
          })

          if (previewable) {
            previewPromise.then((dataUrl) => {
              if (!dataUrl) return
              editor.update(() => {
                const currentNode = $getNodeByKey(nodeKey)
                if ($isActionTextAttachmentNode(currentNode)) {
                  currentNode.setLocalPreview(dataUrl)
                }
              })
              readImageDimensions(dataUrl).then(({width, height}) => {
                if (!width || !height) return
                editor.update(() => {
                  const currentNode = $getNodeByKey(nodeKey)
                  if ($isActionTextAttachmentNode(currentNode)) {
                    currentNode.setDimensions(width, height)
                  }
                })
              })
            })
          }

          incrementUploads()

          const rootElement = editor.getRootElement()
          const uploadContainer = rootElement?.closest("[data-direct-upload-url]")
          const resolvedDirectUploadUrl = directUploadUrl || uploadContainer?.dataset.directUploadUrl
          const resolvedBlobUrlTemplate = blobUrlTemplate || uploadContainer?.dataset.blobUrlTemplate

          const UploadConstructor =
            (typeof window !== "undefined" && window.ActiveStorage?.DirectUpload) ||
            ModuleDirectUpload

          const delegate = {
            directUploadWillStoreFileWithXHR(xhr) {
              xhr.upload.addEventListener("progress", (event) => {
                if (!event.lengthComputable) return
                const progress = Math.round((event.loaded / event.total) * 100)
                editor.update(() => {
                  const currentNode = $getNodeByKey(nodeKey)
                  if ($isActionTextAttachmentNode(currentNode)) {
                    currentNode.setProgress(progress)
                  }
                })
              })
            }
          }

          if (!resolvedDirectUploadUrl || !resolvedBlobUrlTemplate || !UploadConstructor) {
            editor.update(() => {
              const currentNode = $getNodeByKey(nodeKey)
              if ($isActionTextAttachmentNode(currentNode)) {
                currentNode.markUploadError("Direct upload unavailable")
              }
            })
            decrementUploads()
            return
          }

          const upload = new UploadConstructor(file, resolvedDirectUploadUrl, delegate)
          if (typeof window !== "undefined") {
            window.__lexicalDirectUploadDebug = {
              lastStartedAt: Date.now(),
              filename: file.name,
              directUploadUrl: resolvedDirectUploadUrl
            }
          }
          upload.create((error, attributes) => {
            if (error) {
              editor.update(() => {
                const currentNode = $getNodeByKey(nodeKey)
                if ($isActionTextAttachmentNode(currentNode)) {
                  currentNode.markUploadError(error?.message || "Upload failed")
                }
              })
              decrementUploads()
              return
            }

            const url = resolvedBlobUrlTemplate
              .replace(":signed_id", attributes.signed_id)
              .replace(":filename", encodeURIComponent(attributes.filename))

            editor.update(() => {
              const currentNode = $getNodeByKey(nodeKey)
              if ($isActionTextAttachmentNode(currentNode)) {
                const existing = currentNode.getPayload()
                currentNode.applyUploadResult(
                  sanitizeAttachmentPayload({
                    sgid: attributes.attachable_sgid,
                    url,
                    filename: attributes.filename,
                    contentType: attributes.content_type,
                    filesize: attributes.byte_size,
                    status: "ready",
                    previewable: existing.previewable || isImageFile(file),
                    width: existing.width,
                    height: existing.height,
                    caption: existing.caption,
                    localUrl: null
                  })
                )
                currentNode.setProgress(100)
                if (!currentNode.getNextSibling()) {
                  const paragraph = $createParagraphNode()
                  currentNode.insertAfter(paragraph)
                }
              }
            })
            decrementUploads()
          })
        })
      })
    },
    [blobUrlTemplate, decrementUploads, directUploadUrl, editor, incrementUploads]
  )

  useEffect(() => {
    return mergeRegister(
      editor.registerCommand(
        INSERT_ACTIONTEXT_ATTACHMENT_COMMAND,
        (payload) => {
          if (!payload || !payload.file) return false
          startDirectUpload(payload.file, payload.options || {})
          return true
        },
        COMMAND_PRIORITY_EDITOR
      ),
      editor.registerCommand(
        PASTE_COMMAND,
        (event) => {
          const files = event.clipboardData?.files
          if (!files || files.length === 0) return false
          event.preventDefault()
          Array.from(files).forEach((file) => {
            startDirectUpload(file)
          })
          return true
        },
        COMMAND_PRIORITY_EDITOR
      ),
      editor.registerCommand(
        DROP_COMMAND,
        (event) => {
          const files = event.dataTransfer?.files
          if (!files || files.length === 0) return false
          event.preventDefault()
          Array.from(files).forEach((file) => {
            startDirectUpload(file)
          })
          return true
        },
        COMMAND_PRIORITY_EDITOR
      )
    )
  }, [editor, startDirectUpload])

  return null
}
