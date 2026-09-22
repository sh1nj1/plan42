import { useEffect, useCallback, useRef } from "react"
import { DirectUpload as ModuleDirectUpload } from "@rails/activestorage"
import { useLexicalComposerContext } from "@lexical/react/LexicalComposerContext"
import { mergeRegister } from "@lexical/utils"
import {
    $createParagraphNode,
    $getSelection,
    $isRangeSelection,
    $getRoot,
    COMMAND_PRIORITY_EDITOR,
    PASTE_COMMAND,
    createCommand
} from "lexical"

import { $createImageNode } from "../../lib/lexical/image_node"
import { $createAttachmentNode } from "../../lib/lexical/attachment_node"
import { $createVideoNode } from "../../lib/lexical/video_node"

import { registerFileDrop } from "../../lib/lexical/file_drop"

export const INSERT_IMAGE_COMMAND = createCommand("INSERT_IMAGE_COMMAND")
export const INSERT_FILE_COMMAND = createCommand("INSERT_FILE_COMMAND")

function isImageFile(file) {
    if (!file) return false
    if (file.type) return /^image\//i.test(file.type)
    return /\.(bmp|gif|jpe?g|png|svg|webp)$/i.test(file.name || "")
}

function isVideoFile(file) {
    if (!file) return false
    if (file.type) return /^video\//i.test(file.type)
    return /\.(mp4|webm|mov|m4v)$/i.test(file.name || "")
}

function uploadCompletion(editor, commitUpload, finishUpload) {
    return (insert = () => {}) => {
        if (commitUpload) commitUpload(insert, finishUpload)
        else editor.update(insert, { onUpdate: finishUpload })
    }
}

export default function FileUploadPlugin({
    onUploadStateChange,
    directUploadUrl,
    blobUrlTemplate
}) {
    const [editor] = useLexicalComposerContext()
    const pendingUploads = useRef(0)
    const finishUpload = useCallback(() => {
        pendingUploads.current -= 1
        onUploadStateChange?.(pendingUploads.current > 0)
    }, [onUploadStateChange])

    const startDirectUpload = useCallback(
        (file, commitUpload) => {
            if (!file) return

            const complete = uploadCompletion(editor, commitUpload, finishUpload)

            pendingUploads.current += 1
            if (onUploadStateChange) onUploadStateChange(true)

            const rootElement = editor.getRootElement()
            const uploadContainer = rootElement?.closest("[data-direct-upload-url]")
            const resolvedDirectUploadUrl = directUploadUrl || uploadContainer?.dataset.directUploadUrl
            const resolvedBlobUrlTemplate = blobUrlTemplate || uploadContainer?.dataset.blobUrlTemplate

            const UploadConstructor =
                (typeof window !== "undefined" && window.ActiveStorage?.DirectUpload) ||
                ModuleDirectUpload

            if (!resolvedDirectUploadUrl || !resolvedBlobUrlTemplate || !UploadConstructor) {
                console.error("Direct upload configuration missing")
                complete()
                return
            }

            const upload = new UploadConstructor(file, resolvedDirectUploadUrl)

            upload.create((error, attributes) => {
                if (error) {
                    console.error("Upload failed", error)
                    complete()
                    return
                }

                const url = resolvedBlobUrlTemplate
                    .replace(":signed_id", attributes.signed_id)
                    .replace(":filename", encodeURIComponent(attributes.filename))

                complete(() => {
                    let node

                    if (isImageFile(file)) {
                        node = $createImageNode({
                            src: url,
                            altText: attributes.filename,
                            maxWidth: 800 // Default max width
                        })
                    } else if (isVideoFile(file)) {
                        node = $createVideoNode({
                            src: url,
                            filename: attributes.filename
                        })
                    } else {
                        node = $createAttachmentNode({
                            src: url,
                            filename: attributes.filename,
                            filesize: file.size
                        })
                    }

                    const selection = $getSelection()
                    if ($isRangeSelection(selection)) {
                        selection.insertNodes([node])
                        // Insert a paragraph after so user can continue typing
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
                })
            })
        },
        [blobUrlTemplate, directUploadUrl, editor, onUploadStateChange, finishUpload]
    )

    useEffect(() => {
        return mergeRegister(
            editor.registerCommand(
                INSERT_IMAGE_COMMAND,
                (payload) => {
                    if (!payload || !payload.file) return false
                    startDirectUpload(payload.file)
                    return true
                },
                COMMAND_PRIORITY_EDITOR
            ),
            editor.registerCommand(
                INSERT_FILE_COMMAND,
                (payload) => {
                    if (!payload || !payload.file) return false
                    startDirectUpload(payload.file)
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
            registerFileDrop(editor, startDirectUpload)
        )
    }, [editor, startDirectUpload])

    return null
}
