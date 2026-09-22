import { useEffect } from "react"
import { useLexicalComposerContext } from "@lexical/react/LexicalComposerContext"
import { registerCreativeLinkDrop } from "../../lib/lexical/creative_link_drop"
import { registerCreativeLinkTrigger } from "../../lib/lexical/creative_link_trigger"

export default function CreativeLinksPlugin() {
  const [editor] = useLexicalComposerContext()
  useEffect(() => registerCreativeLinkDrop(editor), [editor])

  useEffect(() => registerCreativeLinkTrigger(editor, ({ anchorRect, onSelect, onClose }) => {
    const modal = document.getElementById("link-creative-modal")
    const controller = modal && window.Stimulus?.getControllerForElementAndIdentifier(
      modal,
      "link-creative"
    )
    if (!controller) return false

    controller.open(anchorRect, onSelect, onClose, { allowCreate: true })
    return true
  }), [editor])

  return null
}

