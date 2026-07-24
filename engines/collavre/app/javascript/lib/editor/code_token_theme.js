// Prism token type → CSS class map for code-block syntax highlighting.
//
// Single source of truth shared by the Lexical editor
// (components/InlineLexicalEditor.jsx, passed as theme.codeHighlight to
// registerCodeHighlighting) and the rendered creative view
// (lib/utils/markdown.js highlightCodeBlocks). Both tokenize code with the same
// Prism instance and tag each token with these `lexical-token-*` classes, so
// edit mode and rendered mode are colored identically by the shared
// `.lexical-token-*` rules in actiontext.css. One map means the two surfaces
// can never drift apart.
export const CODE_TOKEN_THEME = {
  atrule: "lexical-token-atrule",
  attr: "lexical-token-attr",
  boolean: "lexical-token-boolean",
  builtin: "lexical-token-builtin",
  cdata: "lexical-token-cdata",
  char: "lexical-token-char",
  class: "lexical-token-class",
  comment: "lexical-token-comment",
  constant: "lexical-token-constant",
  deleted: "lexical-token-deleted",
  doctype: "lexical-token-doctype",
  entity: "lexical-token-entity",
  function: "lexical-token-function",
  important: "lexical-token-important",
  inserted: "lexical-token-inserted",
  keyword: "lexical-token-keyword",
  namespace: "lexical-token-namespace",
  number: "lexical-token-number",
  operator: "lexical-token-operator",
  prolog: "lexical-token-prolog",
  property: "lexical-token-property",
  punctuation: "lexical-token-punctuation",
  regex: "lexical-token-regex",
  selector: "lexical-token-selector",
  string: "lexical-token-string",
  symbol: "lexical-token-symbol",
  tag: "lexical-token-tag",
  url: "lexical-token-url",
  variable: "lexical-token-variable"
}
