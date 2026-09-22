import { DecoratorNode } from "lexical"

// A transient inline boundary that moves with the document during an upload.
// It contributes no text or HTML to the saved creative.
export class UploadAnchorNode extends DecoratorNode {
  static getType() { return "upload-anchor" }
  static clone(node) { return new UploadAnchorNode(node.__key) }
  static importJSON() { return new UploadAnchorNode() }
  exportJSON() { return { ...super.exportJSON(), type: "upload-anchor", version: 1 } }
  exportDOM() { return { element: null } }
  createDOM() { return document.createElement("span") }
  updateDOM() { return false }
  decorate() { return null }
  isInline() { return true }
  isKeyboardSelectable() { return false }
}
