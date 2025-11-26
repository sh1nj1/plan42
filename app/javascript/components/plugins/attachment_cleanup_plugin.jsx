import { useEffect, useRef } from "react"
import { useLexicalComposerContext } from "@lexical/react/LexicalComposerContext"
import { $getRoot } from "lexical"
import { $isImageNode } from "../../lib/lexical/image_node"
import { $isAttachmentNode } from "../../lib/lexical/attachment_node"

function extractSignedIdFromUrl(url) {
    if (!url) return null

    // URL format: /rails/active_storage/blobs/:signed_id/:filename
    const match = url.match(/\/rails\/active_storage\/blobs\/([^\/]+)\//)
    return match ? match[1] : null
}

async function deleteAttachment(signedId) {
    if (!signedId) return

    try {
        const csrfToken = document.querySelector('meta[name="csrf-token"]')?.content
        const response = await fetch(`/attachments/${signedId}`, {
            method: 'DELETE',
            headers: {
                'X-CSRF-Token': csrfToken,
            },
        })

        if (!response.ok) {
            console.error('Failed to delete attachment:', response.statusText)
        }
    } catch (error) {
        console.error('Error deleting attachment:', error)
    }
}

function getAllAttachmentUrls(editor) {
    const urls = new Set()

    editor.getEditorState().read(() => {
        const root = $getRoot()

        function traverse(node) {
            if ($isImageNode(node)) {
                urls.add(node.getSrc())
            } else if ($isAttachmentNode(node)) {
                urls.add(node.getSrc())
            }

            const children = node.getChildren ? node.getChildren() : []
            children.forEach(traverse)
        }

        traverse(root)
    })

    return urls
}

export default function AttachmentCleanupPlugin() {
    const [editor] = useLexicalComposerContext()
    const previousUrlsRef = useRef(new Set())

    useEffect(() => {
        // Initialize with current URLs
        previousUrlsRef.current = getAllAttachmentUrls(editor)

        return editor.registerUpdateListener(({ editorState }) => {
            editorState.read(() => {
                const currentUrls = getAllAttachmentUrls(editor)
                const previousUrls = previousUrlsRef.current

                // Find URLs that were removed
                const removedUrls = Array.from(previousUrls).filter(url => !currentUrls.has(url))

                // Delete attachments for removed URLs
                removedUrls.forEach(url => {
                    const signedId = extractSignedIdFromUrl(url)
                    if (signedId) {
                        deleteAttachment(signedId)
                    }
                })

                // Update previous URLs
                previousUrlsRef.current = currentUrls
            })
        })
    }, [editor])

    return null
}
