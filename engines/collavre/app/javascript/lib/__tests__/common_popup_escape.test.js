/**
 * @jest-environment jsdom
 */
import CommonPopup from '../common_popup'

// setItems() assigns renderItem()'s return value to li.innerHTML, so anything a
// renderer splices in unescaped is parsed as markup. These pin the built-in
// default renderer, which is the one path CommonPopup itself is responsible for.
describe('CommonPopup default renderItem escaping', () => {
    const build = () => {
        const element = document.createElement('div')
        const list = document.createElement('ul')
        element.appendChild(list)
        document.body.appendChild(element)
        return { popup: new CommonPopup(element, { listElement: list }), list }
    }

    afterEach(() => { document.body.innerHTML = '' })

    test('a hostile label is rendered as text, not as an element', () => {
        const { popup, list } = build()
        popup.setItems([{ label: '<img src=x onerror="window.__xss = true">' }])

        expect(list.querySelector('img')).toBeNull()
        expect(list.querySelector('li').textContent).toBe('<img src=x onerror="window.__xss = true">')
    })

    test('the escaping does not disturb an ordinary label', () => {
        const { popup, list } = build()
        popup.setItems([{ label: 'Plain Name' }])
        expect(list.querySelector('li').textContent).toBe('Plain Name')
    })

    test('a caller-supplied renderItem still owns its own escaping', () => {
        // Documents the contract rather than changing it: renderItem returns markup
        // by design (the mention/command menus emit real elements), so CommonPopup
        // cannot escape it centrally without breaking every caller.
        const element = document.createElement('div')
        const list = document.createElement('ul')
        element.appendChild(list)
        document.body.appendChild(element)

        const popup = new CommonPopup(element, {
            listElement: list,
            renderItem: (item) => `<b class="x">${item.label}</b>`,
        })
        popup.setItems([{ label: 'bold' }])
        expect(list.querySelector('b.x')).not.toBeNull()
    })
})
