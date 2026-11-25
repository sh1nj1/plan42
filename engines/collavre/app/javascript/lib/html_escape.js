// Callers retain their own coercion; this function expects a string.
export function escapeHtmlText(text) {
    return text.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;')
}

export function escapeHtmlDoubleQuoted(text) {
    return escapeHtmlText(text).replace(/"/g, '&quot;')
}

export function escapeHtmlAttribute(text) {
    return escapeHtmlDoubleQuoted(text).replace(/'/g, '&#039;')
}
