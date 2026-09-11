const DEFAULT_WIDTH = 420
const DEFAULT_HEIGHT = 640
const DEFAULT_TOP = 100

function popupDimensions(savedStyles) {
  const finalWidth = savedStyles?.width || ''
  const finalHeight = savedStyles?.height || ''

  return {
    finalWidth,
    finalHeight,
    animWidth: parseFloat(finalWidth) || DEFAULT_WIDTH,
    animHeight: parseFloat(finalHeight) || DEFAULT_HEIGHT,
  }
}

function buttonTarget(targetButton, dimensions, viewport) {
  const btnRect = targetButton.getBoundingClientRect()
  const proposedTop = btnRect.bottom + 4
  const animTop = proposedTop + dimensions.animHeight > viewport.height
    ? Math.max(4, viewport.height - dimensions.animHeight - 4)
    : proposedTop
  const exitToRight = viewport.width - btnRect.right - 8 >= dimensions.animWidth
  const rightPx = viewport.width - btnRect.right + 24

  return {
    ...dimensions,
    targetButton,
    finalTop: `${animTop}px`,
    finalRight: exitToRight ? '' : `${rightPx}px`,
    animTop,
    animLeft: exitToRight ? btnRect.right + 8 : viewport.width - rightPx - dimensions.animWidth,
    exitToRight,
  }
}

function savedTarget(savedStyles, dimensions, viewport) {
  const right = parseFloat(savedStyles.right) || 32

  return {
    ...dimensions,
    targetButton: null,
    finalTop: savedStyles.top || '',
    finalRight: savedStyles.right || '',
    animTop: parseFloat(savedStyles.top) || DEFAULT_TOP,
    animLeft: savedStyles.left
      ? parseFloat(savedStyles.left)
      : viewport.width - right - dimensions.animWidth,
    exitToRight: false,
  }
}

export function findPopupTargetButton(currentButton, creativeId) {
  let targetButton = currentButton
  if (!targetButton && creativeId) {
    const row = document.querySelector(`creative-tree-row[creative-id="${creativeId}"]`)
    targetButton = row?.querySelector('.comments-btn')
  }
  targetButton?.closest('creative-tree-row')?.scrollIntoView({ behavior: 'instant', block: 'center' })
  return targetButton
}

export function popupExitTarget({ targetButton, savedStyles, viewport }) {
  const dimensions = popupDimensions(savedStyles)
  if (targetButton) return buttonTarget(targetButton, dimensions, viewport)
  if (savedStyles && Object.values(savedStyles).some(value => value)) {
    return savedTarget(savedStyles, dimensions, viewport)
  }

  return {
    ...dimensions,
    targetButton: null,
    finalTop: '',
    finalRight: '',
    animTop: DEFAULT_TOP,
    animLeft: viewport.width - 32 - dimensions.animWidth,
    exitToRight: false,
  }
}

export function restorePopupTargetStyles(style, target) {
  style.top = target.finalTop
  style.width = target.finalWidth
  style.height = target.finalHeight
  if (target.exitToRight) {
    style.left = `${target.animLeft}px`
    style.right = ''
  } else {
    style.right = target.finalRight
    style.left = ''
  }
}
