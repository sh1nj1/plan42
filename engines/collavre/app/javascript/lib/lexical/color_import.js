import { $isElementNode, $isTextNode } from "lexical"

function applyStyleToTextNodes(nodes, styleText) {
  nodes.forEach((node) => {
    if ($isTextNode(node)) {
      node.setStyle(styleText)
    } else if ($isElementNode(node)) {
      applyStyleToTextNodes(node.getChildren(), styleText)
    }
  })
}

// Custom HTML import for <span> that binds inline color / background-color to
// the text nodes it produces, at import time.
//
// Lexical's default span import (applyTextFormatFromStyle) only reads
// font-weight / font-style / text-decoration — it ignores color and
// background-color. The editor used to compensate by collecting one style per
// DOM text node and re-applying them positionally to root.getAllTextNodes()
// after import. That drifts whenever Lexical's importer does not produce a
// 1:1, same-order mapping of DOM text nodes to lexical text nodes — and it
// frequently does not:
//   - TextNode.exportDOM stamps `white-space: pre-wrap` on every span, so on
//     re-import isNodePre() is true and a span's text is split on "\n"/"\t"
//     into multiple nodes (one DOM text node -> N lexical nodes).
//   - whitespace-only text nodes (e.g. newlines between block tags in
//     server-stored / Trix-migrated HTML) are dropped on import but still
//     counted by the collector.
// Any such mismatch shifts every subsequent color onto the wrong text node, so
// reopening the editor showed the color applied somewhere else (or lost).
//
// Binding the color during conversion keeps it attached to the right node
// regardless of how Lexical splits or drops surrounding text.
export function colorAwareSpanImport(domNode) {
  const { color, backgroundColor } = domNode.style
  if (!color && !backgroundColor) {
    // Defer to Lexical's default span conversion (format-from-style).
    return null
  }

  const declarations = []
  if (color) declarations.push(`color: ${color}`)
  if (backgroundColor) declarations.push(`background-color: ${backgroundColor}`)
  const styleText = declarations.join("; ")

  return {
    conversion: () => ({
      node: null,
      after: (childLexicalNodes) => {
        applyStyleToTextNodes(childLexicalNodes, styleText)
        return childLexicalNodes
      }
    }),
    priority: 1
  }
}

export const lexicalHtmlConfig = {
  import: {
    span: colorAwareSpanImport
  }
}
