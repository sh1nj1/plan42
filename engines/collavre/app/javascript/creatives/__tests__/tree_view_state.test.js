/**
 * @jest-environment jsdom
 */
import { captureCreativeTreeViewState, restoreCreativeTreeViewState } from '../tree_view_state'

function row(id, expanded = false) {
  return `
    <creative-tree-row creative-id="${id}" ${expanded ? 'expanded' : ''}>
      <div class="creative-tree"><button id="toggle-${id}">Toggle</button></div>
    </creative-tree-row>
    <div id="creative-children-${id}" style="display: ${expanded ? '' : 'none'}"></div>
  `
}

describe('creative tree view state', () => {
  test('restores expansion, focus, and the workspace main scroll position', () => {
    document.body.innerHTML = `<main><div id="creatives">${row('1', true)}${row('2')}</div></main>`
    const main = document.querySelector('main')
    const tree = document.getElementById('creatives')
    main.scrollTop = 180
    document.getElementById('toggle-2').focus()
    const state = captureCreativeTreeViewState(tree)

    tree.innerHTML = `${row('1')}${row('2', true)}`
    main.scrollTop = 0
    restoreCreativeTreeViewState(tree, state)

    expect(tree.querySelector('creative-tree-row[creative-id="1"]').hasAttribute('expanded')).toBe(true)
    expect(tree.querySelector('creative-tree-row[creative-id="2"]').hasAttribute('expanded')).toBe(false)
    expect(document.getElementById('creative-children-1').style.display).toBe('')
    expect(document.getElementById('creative-children-2').style.display).toBe('none')
    expect(main.scrollTop).toBe(180)
    expect(document.activeElement.id).toBe('toggle-2')
  })

  test('ignores rows and controls that disappear during reload', () => {
    document.body.innerHTML = `<main><div id="creatives">${row('1', true)}</div></main>`
    const tree = document.getElementById('creatives')
    document.getElementById('toggle-1').focus()
    const state = captureCreativeTreeViewState(tree)

    tree.replaceChildren()

    expect(() => restoreCreativeTreeViewState(tree, state)).not.toThrow()
  })

  // A row's controls are rebuilt without their ids on some renders, so the
  // captured position is the only way back to the same control.
  test('restores an anonymous control by its position in the row', () => {
    document.body.innerHTML = `
      <main><div id="creatives">
        <creative-tree-row creative-id="1">
          <button>First</button><button>Second</button>
        </creative-tree-row>
      </div></main>
    `
    const tree = document.getElementById('creatives')
    tree.querySelectorAll('button')[1].focus()

    const state = captureCreativeTreeViewState(tree)
    expect(state.focus).toMatchObject({ creativeId: '1', controlId: null, controlIndex: 1 })

    tree.innerHTML = `
      <creative-tree-row creative-id="1">
        <button>First</button><button>Second</button>
      </creative-tree-row>
    `
    restoreCreativeTreeViewState(tree, state)

    expect(document.activeElement.textContent).toBe('Second')
  })

  test('restores a scroll position captured without any expansion record', () => {
    document.body.innerHTML = `<main><div id="creatives">${row('1')}</div></main>`
    const main = document.querySelector('main')
    const tree = document.getElementById('creatives')

    restoreCreativeTreeViewState(tree, { scrolling: main, scrollTop: 42, focus: null })

    expect(main.scrollTop).toBe(42)
  })
})
