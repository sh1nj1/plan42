import { openingFocusOptions } from '../popup_focus'

afterEach(() => { document.body.innerHTML = '' })

test('only the focused opener is included in autofocus options', () => {
  const opener = document.createElement('button')
  const other = document.createElement('button')
  document.body.append(opener, other)

  expect(openingFocusOptions(null)).toEqual({})
  other.focus()
  expect(openingFocusOptions(opener)).toEqual({})
  opener.focus()
  expect(openingFocusOptions(opener)).toEqual({ openingControl: opener })
})
