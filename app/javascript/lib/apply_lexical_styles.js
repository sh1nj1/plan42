import {syncLexicalStyleAttributes} from "./lexical/style_attributes"

export function applyLexicalStyles(root = document) {
  syncLexicalStyleAttributes(root)
}

const handleLoad = (event) => {
  const target = event?.target instanceof Element ? event.target : document
  applyLexicalStyles(target)
}

document.addEventListener("turbo:load", handleLoad)
document.addEventListener("turbo:frame-load", handleLoad)

applyLexicalStyles(document)
