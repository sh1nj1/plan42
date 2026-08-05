// HTML escaping for the places we build markup as strings.
//
// Two functions rather than one because the escape sets differ: text content
// only has to neutralize `&`, `<` and `>`, while an attribute value spliced
// between double quotes must also neutralize `"` or it closes the attribute
// early and everything after it is parsed as further attributes (the classic
// `" onerror="…` break-out). Using the text variant on an attribute is the
// mistake this split exists to make hard.
//
// `null`/`undefined` render as the empty string rather than the literal
// "null"/"undefined", which is what every call site here wants for a missing
// avatar or label.

export function escapeHtmlText(value) {
  return String(value == null ? "" : value)
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
}

export function escapeHtmlAttr(value) {
  return String(value == null ? "" : value)
    .replace(/&/g, "&amp;")
    .replace(/"/g, "&quot;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
}
