export function setupImagePan(controller, stage) {
  stage.addEventListener("pointerdown", (event) => {
    if (controller._drag) {
      controller._drag = null
      controller._applyTransform()
      return
    }
    if (controller._zoom <= 1 || event.button !== 0 || !event.isPrimary) return
    event.preventDefault()
    controller._drag = {
      id: event.pointerId, x: event.clientX, y: event.clientY,
      panX: controller._panX, panY: controller._panY
    }
    stage.setPointerCapture(event.pointerId)
    controller._applyTransform()
  })
  stage.addEventListener("pointermove", (event) => {
    if (!controller._drag || controller._drag.id !== event.pointerId) return
    controller._panX = controller._drag.panX + event.clientX - controller._drag.x
    controller._panY = controller._drag.panY + event.clientY - controller._drag.y
    controller._applyTransform()
  })
  const stop = () => {
    controller._drag = null
    controller._applyTransform()
  }
  stage.addEventListener("pointerup", stop)
  stage.addEventListener("pointercancel", stop)
  stage.addEventListener("lostpointercapture", stop)
}

