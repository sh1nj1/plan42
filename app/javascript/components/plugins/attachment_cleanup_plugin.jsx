import { useEffect, useRef } from "react"
import { useLexicalComposerContext } from "@lexical/react/LexicalComposerContext"
import { $getRoot } from "lexical"
import { $isImageNode } from "../../lib/lexical/image_node"
import { $isAttachmentNode } from "../../lib/lexical/attachment_node"

function extractSignedIdFromUrl(url) {
    if (!url) return null

    // URL format: /rails/active_storage/blobs/redirect/:signed_id/:filename
    // or: /rails/active_storage/blobs/proxy/:signed_id/:filename
    // or: /rails/active_storage/blobs/:signed_id/:filename
    const match = url.match(/\/rails\/active_storage\/blobs\/(?:redirect|proxy)\/([^\/]+)\//)
    if (match) return match[1]

    // Fallback for direct blob URLs without redirect/proxy
    const directMatch = url.match(/\/rails\/active_storage\/blobs\/([^\/]+)\//)
    return directMatch ? directMatch[1] : null
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

export default function AttachmentCleanupPlugin({ deletedAttachmentsRef }) {
    const [editor] = useLexicalComposerContext()
    const allSeenUrlsRef = useRef(new Set())

    useEffect(() => {
        // Initialize with current URLs
        const initialUrls = getAllAttachmentUrls(editor)
        initialUrls.forEach(url => allSeenUrlsRef.current.add(url))

        return editor.registerUpdateListener(({ editorState }) => {
            editorState.read(() => {
                const currentUrls = getAllAttachmentUrls(editor)

                // Add any new URLs to allSeenUrls
                currentUrls.forEach(url => allSeenUrlsRef.current.add(url))

                // Calculate removed URLs (seen but not currently present)
                const removedUrls = Array.from(allSeenUrlsRef.current).filter(url => !currentUrls.has(url))

                // Update the ref with signed IDs of removed attachments
                if (deletedAttachmentsRef) {
                    const removedSignedIds = removedUrls
                        .map(url => extractSignedIdFromUrl(url))
                        .filter(Boolean)

                    deletedAttachmentsRef.current = removedSignedIds
                }
            })
        })
    }, [editor, deletedAttachmentsRef])

    return null
}
