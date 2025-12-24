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
  const creativeExclusion = getCreativesExclusion()

  for (let i = 0; i < snowflakes; i += 1) {
    const flake = document.createElement("span")
    flake.className = "snowflake"

    const size = randomInRange(2, 6)
    const fallDuration = randomInRange(12, 26)
    const swayOffset = randomInRange(-15, 15)
    const swayRange = randomInRange(12, 30)

    let position = Math.random() * 100

    if (creativeExclusion) {
      position = findPositionOutsideExclusion(position, creativeExclusion)
    }

    flake.style.left = `${position}%`
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

function getCreativesExclusion() {
  const creatives = document.getElementById("creatives")
  if (!creatives) return null

  const bounds = creatives.getBoundingClientRect()
  const viewportWidth = window.innerWidth || document.documentElement.clientWidth
  if (!viewportWidth) return null

  const left = Math.max(0, Math.min(100, (bounds.left / viewportWidth) * 100))
  const right = Math.max(0, Math.min(100, (bounds.right / viewportWidth) * 100))

  if (right - left <= 0) return null

  return { left, right }
}

function findPositionOutsideExclusion(initial, exclusion) {
  let position = initial
  let attempts = 0

  while (
    position >= exclusion.left &&
    position <= exclusion.right &&
    attempts < 6
  ) {
    position = Math.random() * 100
    attempts += 1
  }

  if (position >= exclusion.left && position <= exclusion.right) {
    const leftGap = exclusion.left
    const rightGap = 100 - exclusion.right

    if (leftGap >= rightGap && leftGap > 0) {
      position = Math.random() * exclusion.left
    } else if (rightGap > 0) {
      position = exclusion.right + Math.random() * rightGap
    }
  }

  return position
}
