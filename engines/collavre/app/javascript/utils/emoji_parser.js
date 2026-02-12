const DEFAULT_EMOJIS = ['🎨', '💡', '🚀', '✨', '🧩', '🎲']

/**
 * Parse a CSS custom property string of emojis into an array.
 * Supports both comma-separated ("🔵, 🔴, 🟡") and concatenated ("🍅🔴🌶️") formats.
 *
 * @param {string} emojiString - raw string from CSS --creative-loading-emojis
 * @returns {string[]} array of individual emoji characters
 */
export function parseEmojis(emojiString) {
  if (!emojiString) return DEFAULT_EMOJIS

  let emojis
  if (emojiString.includes(',')) {
    emojis = emojiString.split(',').map(e => e.trim()).filter(e => e)
  } else {
    emojis = [...emojiString.matchAll(/\p{Extended_Pictographic}(?:\u{FE0F}|\u{200D}\p{Extended_Pictographic})*/gu)].map(m => m[0])
  }

  return emojis.length > 0 ? emojis : DEFAULT_EMOJIS
}
