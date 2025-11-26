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
    const redirectMatch = url.match(/\/rails\/active_storage\/blobs\/(?:redirect|proxy)\/([^\/?#]+)(?=[\/?#]|$)/)
    if (redirectMatch) return redirectMatch[1]

    // Fallback for direct blob URLs without redirect/proxy
    const directMatch = url.match(/\/rails\/active_storage\/blobs\/([^\/?#]+)(?=[\/?#]|$)/)
    return directMatch ? directMatch[1] : null
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
    const removedSignedIdsRef = useRef(new Set())

    useEffect(() => {
        // Initialize with current URLs
        const initialUrls = getAllAttachmentUrls(editor)
        initialUrls.forEach(url => allSeenUrlsRef.current.add(url))

        const unregister = editor.registerUpdateListener(({ editorState }) => {
            editorState.read(() => {
                const currentUrls = getAllAttachmentUrls(editor)
                const currentSignedIds = new Set(
                    Array.from(currentUrls)
                        .map(url => extractSignedIdFromUrl(url))
                        .filter(Boolean)
                )

                // Add any new URLs to allSeenUrls
                currentUrls.forEach(url => allSeenUrlsRef.current.add(url))

                // Calculate removed URLs (seen but not currently present)
                const removedUrls = Array.from(allSeenUrlsRef.current).filter(url => !currentUrls.has(url))

                const removedSignedIds = removedUrls
                    .map(url => extractSignedIdFromUrl(url))
                    .filter(Boolean)

                // If an attachment was previously removed but has been reinserted,
                // drop it from the removal set to avoid purging restored blobs.
                currentSignedIds.forEach(id => removedSignedIdsRef.current.delete(id))

                removedSignedIds.forEach(id => removedSignedIdsRef.current.add(id))

                if (deletedAttachmentsRef) {
                    deletedAttachmentsRef.current = Array.from(removedSignedIdsRef.current)
                }
            })
        })

        return () => {
            unregister()
            removedSignedIdsRef.current.clear()
            if (deletedAttachmentsRef) {
                deletedAttachmentsRef.current = []
            }
        }
    }, [editor, deletedAttachmentsRef])

    return null
}
