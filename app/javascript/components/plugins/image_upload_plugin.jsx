import { useEffect, useCallback } from "react"
import { DirectUpload as ModuleDirectUpload } from "@rails/activestorage"
import { useLexicalComposerContext } from "@lexical/react/LexicalComposerContext"
import { mergeRegister } from "@lexical/utils"
import {
    $createParagraphNode,
    $getSelection,
    $isRangeSelection,
    $getRoot,
    COMMAND_PRIORITY_EDITOR,
    DROP_COMMAND,
    PASTE_COMMAND,
    createCommand
} from "lexical"

import { $createImageNode } from "../../lib/lexical/image_node"

export const INSERT_IMAGE_COMMAND = createCommand("INSERT_IMAGE_COMMAND")

function isImageFile(file) {
    if (!file) return false
    if (file.type) return /^image\//i.test(file.type)
    return /\.(bmp|gif|jpe?g|png|svg|webp)$/i.test(file.name || "")
}

export default function ImageUploadPlugin({
    onUploadStateChange,
    directUploadUrl,
    blobUrlTemplate
}) {
    const [editor] = useLexicalComposerContext()

    const startDirectUpload = useCallback(
        (file) => {
            if (!file || !isImageFile(file)) return

            // Notify start
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
                if (onUploadStateChange) onUploadStateChange(false)
                return
            }

            const upload = new UploadConstructor(file, resolvedDirectUploadUrl)

            upload.create((error, attributes) => {
                if (onUploadStateChange) onUploadStateChange(false)

                if (error) {
                    console.error("Upload failed", error)
                    return
                }

                const url = resolvedBlobUrlTemplate
                    .replace(":signed_id", attributes.signed_id)
                    .replace(":filename", encodeURIComponent(attributes.filename))

                editor.update(() => {
                    const imageNode = $createImageNode({
                        src: url,
                        altText: attributes.filename,
                        maxWidth: 800 // Default max width
                    })

                    const selection = $getSelection()
                    if ($isRangeSelection(selection)) {
                        selection.insertNodes([imageNode])
                        // Insert a paragraph after so user can continue typing
                        const paragraph = $createParagraphNode()
                        imageNode.insertAfter(paragraph)
                        paragraph.selectStart()
                    } else {
                        const root = $getRoot()
                        root.append(imageNode)
                        const paragraph = $createParagraphNode()
                        root.append(paragraph)
                        paragraph.selectStart()
                    }
                })
            })
        },
        [blobUrlTemplate, directUploadUrl, editor, onUploadStateChange]
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
                PASTE_COMMAND,
                (event) => {
                    const files = event.clipboardData?.files
                    if (!files || files.length === 0) return false

                    const imageFiles = Array.from(files).filter(isImageFile)
                    if (imageFiles.length === 0) return false

                    event.preventDefault()
                    imageFiles.forEach((file) => {
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

                    const imageFiles = Array.from(files).filter(isImageFile)
                    if (imageFiles.length === 0) return false

                    event.preventDefault()
                    imageFiles.forEach((file) => {
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
