import { createElement as h, useEffect, useRef, useState } from 'react'
import { $getRoot, $getSelection, $isRangeSelection, $setSelection } from 'lexical'

const EMOJIS = '😀 😃 😄 😁 😆 😅 😂 🤣 😊 🙂 😉 😍 🥰 😘 😎 🤔 😮 😢 😭 😡 🥳 😴 👍 👎 👏 🙌 🙏 💪 👋 🤝 ❤️ 🧡 💛 💚 💙 💜 🔥 ⭐ 🌟 ✨ 🎉 🎊 🎁 🎯 🚀 💡 ✅ ❌ ⚠️ 📌 📝 📅 🔖 📚 🗂️ 🔍'.split(' ')

function useDismiss(open, wrapper, trigger, close) {
  useEffect(() => {
    if (!open) return
    const outside = (event) => {
      if (!wrapper.current.contains(event.target)) close(false)
    }
    const escape = (event) => {
      if (event.key !== 'Escape') return
      event.preventDefault()
      event.stopPropagation()
      close(false)
      trigger.current.focus()
    }
    document.addEventListener('mousedown', outside)
    document.addEventListener('keydown', escape, true)
    return () => {
      document.removeEventListener('mousedown', outside)
      document.removeEventListener('keydown', escape, true)
    }
  }, [open, wrapper, trigger, close])
}

function EmojiChoices({ label, choose }) {
  const ref = useRef(null)
  useEffect(() => { ref.current.querySelector('button').focus() }, [])
  return h('div', { ref, className: 'lexical-emoji-picker__popup', role: 'dialog', 'aria-label': label },
    EMOJIS.map((emoji) => h('button', {
      key: emoji, type: 'button', className: 'lexical-toolbar-btn',
      onClick: () => choose(emoji), 'aria-label': emoji
    }, emoji)))
}

export default function EmojiPicker({ editor, label }) {
  const [open, setOpen] = useState(false)
  const wrapper = useRef(null)
  const trigger = useRef(null)
  const savedSelection = useRef(null)
  useDismiss(open, wrapper, trigger, setOpen)
  const toggle = () => {
    if (!open) editor.getEditorState().read(() => {
      const selection = $getSelection()
      savedSelection.current = $isRangeSelection(selection) ? selection.clone() : null
    })
    setOpen(!open)
  }
  const choose = (emoji) => {
    editor.update(() => {
      if (savedSelection.current) $setSelection(savedSelection.current.clone())
      const selection = $getSelection()
      const range = $isRangeSelection(selection) ? selection : $getRoot().selectEnd()
      range.insertText(emoji)
    })
    setOpen(false)
    editor.focus()
  }
  return h('div', { ref: wrapper, className: 'lexical-emoji-picker' },
    h('button', {
      ref: trigger, type: 'button', className: 'lexical-toolbar-btn',
      title: label, 'aria-label': label, 'aria-haspopup': 'dialog', 'aria-expanded': open,
      onMouseDown: (event) => event.preventDefault(), onClick: toggle
    }, '☺'),
    open && h(EmojiChoices, { label, choose }))
}
