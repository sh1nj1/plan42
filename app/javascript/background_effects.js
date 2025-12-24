const effects = {
  snowfall: createSnowfallEffect
}

let cleanupCurrentEffect = null

export function applyBackgroundEffect(effectName = "snowfall") {
  if (cleanupCurrentEffect) {
    cleanupCurrentEffect()
    cleanupCurrentEffect = null
  }

  const effect = effects[effectName]
  if (!effect) return

  cleanupCurrentEffect = effect()
  document.body.dataset.backgroundEffect = effectName
}

export function registerBackgroundEffect(name, factory) {
  effects[name] = factory
}

function createSnowfallEffect() {
  const layer = document.createElement("div")
  layer.className = "background-effect-layer background-effect--snowfall"

  const count = parseInt(getComputedStyle(layer).getPropertyValue("--snowflake-count"), 10)
  const snowflakes = Number.isFinite(count) ? count : 120

  for (let i = 0; i < snowflakes; i += 1) {
    const flake = document.createElement("span")
    flake.className = "snowflake"

    const size = randomInRange(2, 6)
    const fallDuration = randomInRange(12, 26)
    const swayOffset = randomInRange(-15, 15)
    const swayRange = randomInRange(12, 30)

    flake.style.left = `${Math.random() * 100}%`
    flake.style.setProperty("--snowflake-size", `${size}px`)
    flake.style.setProperty("--snowflake-opacity", `${randomInRange(0.5, 1)}`)
    flake.style.setProperty("--fall-duration", `${fallDuration}s`)
    flake.style.setProperty("--snow-delay", `${Math.random() * 20}s`)
    flake.style.setProperty("--sway-start", `${swayOffset}px`)
    flake.style.setProperty("--sway-offset", `${swayRange}px`)

    layer.appendChild(flake)
  }

  document.body.appendChild(layer)

  return () => {
    layer.remove()
    delete document.body.dataset.backgroundEffect
  }
}

function randomInRange(min, max) {
  return Math.random() * (max - min) + min
}
