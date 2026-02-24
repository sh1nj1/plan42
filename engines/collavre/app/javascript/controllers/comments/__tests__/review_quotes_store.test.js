import ReviewQuotesStore from '../review_quotes_store'

describe('ReviewQuotesStore', () => {
  let store

  beforeEach(() => {
    store = new ReviewQuotesStore()
  })

  describe('add / remove', () => {
    test('adds a quote and sets it active', () => {
      const q = store.add(1, 'hello world')
      expect(store.count).toBe(1)
      expect(store.activeId).toBe(q.id)
      expect(q.type).toBe('review')
      expect(q.feedback).toBe('')
    })

    test('removes a quote', () => {
      const q = store.add(1, 'text')
      store.remove(q.id)
      expect(store.isEmpty).toBe(true)
      expect(store.activeId).toBeNull()
    })
  })

  describe('feedback', () => {
    test('saves feedback for active quote', () => {
      const q = store.add(1, 'text')
      store.saveActiveFeedback('my feedback')
      expect(q.feedback).toBe('my feedback')
    })

    test('commit deactivates', () => {
      store.add(1, 'text')
      store.commitActive('feedback')
      expect(store.hasActive).toBe(false)
    })
  })

  describe('toggleType', () => {
    test('toggles between review and question', () => {
      const q = store.add(1, 'text')
      store.toggleType(q.id)
      expect(q.type).toBe('question')
      store.toggleType(q.id)
      expect(q.type).toBe('review')
    })
  })

  describe('buttonState', () => {
    test('normal when empty', () => {
      expect(store.buttonState).toBe('normal')
    })

    test('add when active review', () => {
      store.add(1, 'text')
      expect(store.buttonState).toBe('add')
    })

    test('send-question when active question', () => {
      const q = store.add(1, 'text')
      store.toggleType(q.id)
      expect(store.buttonState).toBe('send-question')
    })

    test('send-review when no active', () => {
      store.add(1, 'text')
      store.commitActive('')
      expect(store.buttonState).toBe('send-review')
    })
  })

  describe('buildContent', () => {
    test('builds markdown with quotes and summary', () => {
      const q1 = store.add(1, 'quote one')
      store.commitActive('feedback one')
      store.add(2, 'quote two')
      store.commitActive('feedback two')

      const md = store.buildContent('summary text')
      expect(md).toContain('> quote one')
      expect(md).toContain('feedback one')
      expect(md).toContain('> quote two')
      expect(md).toContain('feedback two')
      expect(md).toContain('---')
      expect(md).toContain('summary text')
    })

    test('question prefix', () => {
      const q = store.add(1, 'why?')
      store.toggleType(q.id)
      const md = store.buildContent('')
      expect(md).toContain('> ❓ why?')
    })
  })

  describe('backup / restore', () => {
    test('restores quotes after backup', () => {
      store.add(1, 'text')
      store.backup('saved textarea')
      // Simulate what happens after send: quotes are manually emptied
      // but backup remains (clear() also wipes backup, so avoid it here)
      store._quotes = []
      store._activeId = null
      expect(store.isEmpty).toBe(true)

      const restored = store.restore()
      expect(restored).toBe('saved textarea')
      expect(store.count).toBe(1)
    })
  })
})
