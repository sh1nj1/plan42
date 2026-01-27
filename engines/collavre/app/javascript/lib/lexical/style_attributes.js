export function syncLexicalStyleAttributes(root) {
  if (!root || typeof root.querySelectorAll !== "function") return

  const elements = root.querySelectorAll(
    "[style], [data-lexical-color], [data-lexical-background-color]"
  )

  elements.forEach((element) => {
    const {style, dataset} = element

    if (style) {
      const color = style.color && style.color.trim()
      const backgroundColor = style.backgroundColor && style.backgroundColor.trim()

      if (color) {
        dataset.lexicalColor = color
      } else if (dataset.lexicalColor) {
        style.color = dataset.lexicalColor
      }

      if (backgroundColor) {
        dataset.lexicalBackgroundColor = backgroundColor
      } else if (dataset.lexicalBackgroundColor) {
        style.backgroundColor = dataset.lexicalBackgroundColor
      }
    } else {
      if (dataset.lexicalColor) {
        element.setAttribute(
          "style",
          `color: ${dataset.lexicalColor};${dataset.lexicalBackgroundColor ? ` background-color: ${dataset.lexicalBackgroundColor};` : ""}`
        )
        return
      }

      if (dataset.lexicalBackgroundColor) {
        element.setAttribute("style", `background-color: ${dataset.lexicalBackgroundColor};`)
      }
    }
  })
}
