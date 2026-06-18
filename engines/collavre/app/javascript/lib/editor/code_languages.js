// Shared code-language resolution for syntax highlighting.
//
// Both the Lexical editor (registerCodeHighlighting) and the rendered creative
// view (lib/utils/markdown.js highlightCodeBlocks) tokenize code with the SAME
// global Prism instance. @lexical/code only preloads a fixed grammar set and its
// `loadCodeLanguage` is a no-op, so any language we want to highlight must be
// registered on the shared `prismjs` singleton up front. The side-effect imports
// below add the common languages @lexical/code omits (ruby, bash, json, yaml,
// go, php); importing this module anywhere makes them available to BOTH surfaces.
// `prismjs` core must load first — the component files mutate the global Prism.
import "prismjs"
import "prismjs/components/prism-ruby"
import "prismjs/components/prism-bash"
import "prismjs/components/prism-json"
import "prismjs/components/prism-yaml"
import "prismjs/components/prism-go"
import "prismjs/components/prism-php"

// A curated highlight.js instance used ONLY for language auto-detection (not for
// rendering — rendering is Prism). A small, codebase-relevant subset keeps
// `highlightAuto` from matching obscure languages (the full set mislabels plain
// JS as "arcade"); detection accuracy comes from limiting the candidates.
import hljs from "highlight.js/lib/core"
import javascript from "highlight.js/lib/languages/javascript"
import typescript from "highlight.js/lib/languages/typescript"
import ruby from "highlight.js/lib/languages/ruby"
import python from "highlight.js/lib/languages/python"
import css from "highlight.js/lib/languages/css"
import xml from "highlight.js/lib/languages/xml"
import json from "highlight.js/lib/languages/json"
import yaml from "highlight.js/lib/languages/yaml"
import bash from "highlight.js/lib/languages/bash"
import sql from "highlight.js/lib/languages/sql"
import go from "highlight.js/lib/languages/go"
import java from "highlight.js/lib/languages/java"

const DETECT_LANGUAGES = {
  javascript, typescript, ruby, python, css, xml, json, yaml, bash, sql, go, java
}
for (const [name, def] of Object.entries(DETECT_LANGUAGES)) {
  if (!hljs.getLanguage(name)) hljs.registerLanguage(name, def)
}
const DETECT_SUBSET = Object.keys(DETECT_LANGUAGES)

// @lexical/code's tokenizer default: an unlabeled or new code block tokenizes as
// JavaScript. We treat that exact value (and an empty/missing language) as
// "unconfirmed" — eligible for re-detection — while honoring any other explicit
// fence language the user set.
export const DEFAULT_CODE_LANGUAGE = "javascript"
const RE_DETECTABLE = new Set(["", "javascript"])

// Canonicalize fence aliases to the Prism grammar name. highlight.js uses a few
// different names (xml↔markup, shell↔bash) so detection results are mapped too.
const FENCE_ALIAS = {
  rb: "ruby",
  py: "python",
  yml: "yaml",
  sh: "bash",
  shell: "bash",
  zsh: "bash",
  ts: "typescript",
  js: "javascript",
  jsx: "javascript",
  tsx: "typescript",
  html: "markup",
  htm: "markup",
  xml: "markup",
  golang: "go"
}

export function normalizeFenceLang(lang) {
  if (!lang) return ""
  const l = String(lang).trim().toLowerCase()
  if (!/^[\w+-]+$/.test(l)) return ""
  return FENCE_ALIAS[l] || l
}

// Minimum margin by which the detected language's relevance must beat plain
// JavaScript's own relevance for the SAME text before we override the
// JavaScript default. This keeps real JS as JS (margin 0) while confidently
// switching Ruby/bash/yaml/python (margins 3–12).
const DETECT_MARGIN = 3
const MIN_DETECT_LENGTH = 12

// Resolve the highlighting language for a code block.
//   - An explicit, non-default fence language ("ruby", "python", …) is honored.
//   - An unlabeled block, or one stuck on the "javascript" default, is
//     re-detected from its content; we only switch away from JavaScript when
//     detection is confident (see DETECT_MARGIN), otherwise the original value
//     is kept. Returns "" for an unlabeled block we can't confidently detect
//     (render as plaintext rather than forcing JavaScript).
export function detectCodeLanguage(code, declared) {
  const norm = normalizeFenceLang(declared)
  if (norm && !RE_DETECTABLE.has(norm)) return norm

  const text = (code || "").trim()
  if (text.length < MIN_DETECT_LENGTH) return norm

  let best
  try {
    best = hljs.highlightAuto(text, DETECT_SUBSET)
  } catch (_e) {
    return norm
  }
  if (!best || !best.language) return norm

  const cand = FENCE_ALIAS[best.language] || best.language
  if (cand === "javascript") return norm

  let jsRelevance = 0
  try {
    jsRelevance = hljs.highlight(text, { language: "javascript" }).relevance
  } catch (_e) {
    jsRelevance = 0
  }
  return best.relevance - jsRelevance >= DETECT_MARGIN ? cand : norm
}
