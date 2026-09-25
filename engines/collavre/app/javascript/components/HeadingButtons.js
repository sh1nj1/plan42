import { createElement as h, useEffect, useState } from 'react'
import { $createParagraphNode, $getSelection, $isRangeSelection, SELECTION_CHANGE_COMMAND, COMMAND_PRIORITY_LOW } from 'lexical'
import { $createHeadingNode, $isHeadingNode } from '@lexical/rich-text'
import { $setBlocksType } from '@lexical/selection'
import { $findMatchingParent, mergeRegister } from '@lexical/utils'

function $selectedHeading() {
  const selection = $getSelection()
  if (!$isRangeSelection(selection)) return null
  const heading = $findMatchingParent(selection.anchor.getNode(), $isHeadingNode)
  return heading ? heading.getTag() : null
}

export default function HeadingButtons({ editor, labels = [] }) {
  const [activeHeading, setActiveHeading] = useState(null)
  useEffect(() => {
    const refresh = () => setActiveHeading($selectedHeading())
    editor.getEditorState().read(refresh)
    return mergeRegister(
      editor.registerUpdateListener(({ editorState }) => editorState.read(refresh)),
      editor.registerCommand(SELECTION_CHANGE_COMMAND, () => {
        refresh()
        return false
      }, COMMAND_PRIORITY_LOW)
    )
  }, [editor])

  const toggle = (tag) => editor.update(() => {
    const selection = $getSelection()
    if (!$isRangeSelection(selection)) return
    const clear = $selectedHeading() === tag
    $setBlocksType(selection, () => clear ? $createParagraphNode() : $createHeadingNode(tag))
  })

  return [1, 2, 3].map((level) => h('button', {
    key: level,
    type: 'button',
    className: `lexical-toolbar-btn ${activeHeading === `h${level}` ? 'active' : ''}`,
    title: labels[level - 1],
    'aria-label': labels[level - 1],
    'aria-pressed': activeHeading === `h${level}`,
    onMouseDown: (event) => event.preventDefault(),
    onClick: () => toggle(`h${level}`)
  }, `H${level}`))
}
