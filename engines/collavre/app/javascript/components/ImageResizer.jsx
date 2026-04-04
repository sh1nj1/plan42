import { useCallback, useEffect, useRef, useState } from "react"
import { useLexicalComposerContext } from "@lexical/react/LexicalComposerContext"
import { useLexicalNodeSelection } from "@lexical/react/useLexicalNodeSelection"
import { mergeRegister } from "@lexical/utils"
import {
  $getNodeByKey,
  $getSelection,
  $isNodeSelection,
  CLICK_COMMAND,
  COMMAND_PRIORITY_LOW,
  KEY_BACKSPACE_COMMAND,
  KEY_DELETE_COMMAND,
} from "lexical"

const MIN_SIZE = 16

function ImageResizeHandle({ position, onPointerDown }) {
  return (
    <div
      className={`lexical-image-handle lexical-image-handle--${position}`}
      onPointerDown={(e) => onPointerDown(e, position)}
      role="separator"
      aria-orientation={position.includes("e") || position.includes("w") ? "horizontal" : "vertical"}
    />
  )
}

export default function ImageResizer({ src, altText, width, height, nodeKey }) {
  const [editor] = useLexicalComposerContext()
  const [isSelected, setSelected, clearSelection] = useLexicalNodeSelection(nodeKey)
  const imageRef = useRef(null)
  const containerRef = useRef(null)
  const [isResizing, setIsResizing] = useState(false)
  const dragStateRef = useRef(null)

  // Handle click on image to select
  const handleClick = useCallback(
    (e) => {
      e.stopPropagation()
      e.preventDefault()
      if (e.shiftKey) {
        setSelected(!isSelected)
      } else {
        clearSelection()
        setSelected(true)
      }
    },
    [isSelected, setSelected, clearSelection]
  )

  // Handle backspace/delete to remove selected image
  useEffect(() => {
    return mergeRegister(
      editor.registerCommand(
        CLICK_COMMAND,
        (event) => {
          // If click is outside our image, deselect
          if (containerRef.current && !containerRef.current.contains(event.target)) {
            setSelected(false)
          }
          return false
        },
        COMMAND_PRIORITY_LOW
      ),
      editor.registerCommand(
        KEY_BACKSPACE_COMMAND,
        (event) => {
          if (isSelected) {
            event.preventDefault()
            editor.update(() => {
              const node = $getNodeByKey(nodeKey)
              if (node) node.remove()
            })
            return true
          }
          return false
        },
        COMMAND_PRIORITY_LOW
      ),
      editor.registerCommand(
        KEY_DELETE_COMMAND,
        (event) => {
          if (isSelected) {
            event.preventDefault()
            editor.update(() => {
              const node = $getNodeByKey(nodeKey)
              if (node) node.remove()
            })
            return true
          }
          return false
        },
        COMMAND_PRIORITY_LOW
      )
    )
  }, [editor, isSelected, nodeKey, setSelected])

  // Resize logic
  const onPointerDown = useCallback(
    (e, position) => {
      e.preventDefault()
      e.stopPropagation()

      const img = imageRef.current
      if (!img) return

      const startX = e.clientX
      const startY = e.clientY
      const startWidth = img.offsetWidth
      const startHeight = img.offsetHeight
      const aspectRatio = startWidth / startHeight

      setIsResizing(true)

      dragStateRef.current = {
        startX,
        startY,
        startWidth,
        startHeight,
        aspectRatio,
        position,
      }

      const onPointerMove = (moveEvent) => {
        const state = dragStateRef.current
        if (!state) return

        let deltaX = moveEvent.clientX - state.startX
        let deltaY = moveEvent.clientY - state.startY

        // Invert deltas for west/north handles
        if (state.position.includes("w")) deltaX = -deltaX
        if (state.position.includes("n")) deltaY = -deltaY

        // Use the larger delta for aspect-ratio-locked resize
        let newWidth, newHeight

        if (Math.abs(deltaX) > Math.abs(deltaY)) {
          newWidth = Math.max(MIN_SIZE, state.startWidth + deltaX)
          newHeight = Math.round(newWidth / state.aspectRatio)
        } else {
          newHeight = Math.max(MIN_SIZE, state.startHeight + deltaY)
          newWidth = Math.round(newHeight * state.aspectRatio)
        }

        // Enforce minimum
        if (newWidth < MIN_SIZE) {
          newWidth = MIN_SIZE
          newHeight = Math.round(newWidth / state.aspectRatio)
        }
        if (newHeight < MIN_SIZE) {
          newHeight = MIN_SIZE
          newWidth = Math.round(newHeight * state.aspectRatio)
        }

        editor.update(() => {
          const node = $getNodeByKey(nodeKey)
          if (node) {
            node.setWidthAndHeight(newWidth, newHeight)
          }
        })
      }

      const onPointerUp = () => {
        setIsResizing(false)
        dragStateRef.current = null
        document.removeEventListener("pointermove", onPointerMove)
        document.removeEventListener("pointerup", onPointerUp)
      }

      document.addEventListener("pointermove", onPointerMove)
      document.addEventListener("pointerup", onPointerUp)
    },
    [editor, nodeKey]
  )

  const imgWidth = width === "inherit" || width === 0 ? "auto" : width
  const imgHeight = height === "inherit" || height === 0 ? "auto" : height

  return (
    <span
      ref={containerRef}
      className={`lexical-image-container${isSelected ? " lexical-image-selected" : ""}${isResizing ? " lexical-image-resizing" : ""}`}
      onClick={handleClick}
      draggable={false}
    >
      <img
        ref={imageRef}
        src={src}
        alt={altText}
        style={{
          width: typeof imgWidth === "number" ? `${imgWidth}px` : imgWidth,
          height: typeof imgHeight === "number" ? `${imgHeight}px` : imgHeight,
          maxWidth: "100%",
          display: "block",
        }}
        draggable={false}
      />
      {isSelected && (
        <>
          <ImageResizeHandle position="nw" onPointerDown={onPointerDown} />
          <ImageResizeHandle position="ne" onPointerDown={onPointerDown} />
          <ImageResizeHandle position="sw" onPointerDown={onPointerDown} />
          <ImageResizeHandle position="se" onPointerDown={onPointerDown} />
        </>
      )}
    </span>
  )
}
