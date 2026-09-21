/**
 * @jest-environment jsdom
 */
import { jest } from '@jest/globals'
import {
  applyCreativeSaveResponse,
  captureDirectCreativeSaveSnapshot,
  captureQueuedCreativeSaveSnapshot,
  captureCreativeSaveSnapshot,
  creativeSaveSnapshotIsEmpty,
  resetCreativeSaveState,
} from '../creative_save_state'

test('captures direct saves from the active editor surface', () => {
  const markdown = captureDirectCreativeSaveSnapshot({
    markdownMode: true,
    markdownContent: '# live',
    htmlContent: '<p>rendered</p>',
    contentType: 'markdown',
    markdownSource: '# live',
    markdownEditor: 'textarea',
    progress: 1,
    persistProgress: true,
    originId: '7',
  })
  const rich = captureDirectCreativeSaveSnapshot({
    markdownMode: false,
    markdownContent: '# cached',
    htmlContent: '<p>live</p>',
    contentType: 'html',
    markdownSource: '# cached',
    markdownEditor: 'rich',
    progress: 0.5,
    persistProgress: false,
    originId: '8',
  })

  expect(markdown).toMatchObject({
    content: '# live', emptyContent: '# live', emptyContentType: 'markdown', progress: 1,
  })
  expect(rich).toMatchObject({
    content: '<p>live</p>', emptyContent: '<p>live</p>', emptyContentType: 'html', progress: 0.5,
  })
})

test('captures queued saves using their persisted content type', () => {
  const markdown = captureQueuedCreativeSaveSnapshot({
    content: '<p>rendered</p>',
    contentType: 'markdown',
    markdownSource: '# source',
    markdownEditor: 'rich',
    progress: 0.5,
    persistProgress: true,
    originId: '9',
  })
  const html = captureQueuedCreativeSaveSnapshot({
    content: '<p>live</p>',
    contentType: 'html',
    markdownSource: '# stale',
  })

  expect(markdown).toMatchObject({
    content: '<p>rendered</p>', emptyContent: '# source', emptyContentType: 'markdown',
    markdownSource: '# source',
  })
  expect(html).toMatchObject({
    content: '<p>live</p>', emptyContent: '<p>live</p>', emptyContentType: 'html',
    markdownSource: '',
  })
})

test('normalizes falsy snapshot strings without changing other values', () => {
  expect(captureCreativeSaveSnapshot({ content: false, markdownSource: 0, originId: null }))
    .toMatchObject({ content: '', markdownSource: '', originId: '' })
})

test('tests emptiness using the snapshot content format', () => {
  const html = captureCreativeSaveSnapshot({
    content: '<p><br></p>',
    emptyContentType: 'html',
  })
  const markdown = captureCreativeSaveSnapshot({
    content: '<p>rendered</p>',
    emptyContent: '   ',
    emptyContentType: 'markdown',
  })

  expect(creativeSaveSnapshotIsEmpty(html)).toBe(true)
  expect(creativeSaveSnapshotIsEmpty(markdown)).toBe(true)
})

test('applies server markdown substitutions to cached and live content', () => {
  const dataUri = 'data:image/png;base64,abc123'
  const snapshot = captureCreativeSaveSnapshot({
    content: `before ${dataUri}`,
    emptyContentType: 'markdown',
    contentType: 'markdown',
    markdownSource: `before ${dataUri}`,
  })
  const applyCurrent = jest.fn()
  const applyCached = jest.fn()

  const result = applyCreativeSaveResponse(
    snapshot,
    { markdown_source: 'before /blob/image' },
    {
      currentMarkdownSource: `before ${dataUri} plus typing`,
      applyCurrentMarkdownSource: applyCurrent,
      applyCachedMarkdownSource: applyCached,
    }
  )

  expect(applyCached).toHaveBeenCalledWith('before /blob/image', `before ${dataUri}`)
  expect(applyCurrent).toHaveBeenCalledWith('before /blob/image plus typing')
  expect(result.snapshot.content).toBe('before /blob/image')
  expect(result.currentApplied).toBe(true)
})

test('resets baselines and preserves dirty state for a newer buffer', () => {
  const snapshot = captureCreativeSaveSnapshot({
    content: 'saved', progress: 1, persistProgress: true, originId: '7',
  })

  const newerBuffer = { content: 'newer', progress: 1, originId: '7' }

  expect(resetCreativeSaveState(snapshot, newerBuffer, true)).toEqual({
    originalContent: 'saved',
    originalProgress: 1,
    originalOriginId: '7',
    isDirty: true,
    pendingSave: false,
  })
  expect(resetCreativeSaveState(snapshot, newerBuffer, false).isDirty).toBe(false)
  expect(resetCreativeSaveState(snapshot).isDirty).toBe(false)
})

test('leaves the live buffer alone when the rewrite cannot be reconciled', () => {
  const dataUri = 'data:image/png;base64,abc123'
  const snapshot = captureCreativeSaveSnapshot({
    content: `before ${dataUri}`,
    emptyContentType: 'markdown',
    contentType: 'markdown',
    markdownSource: `before ${dataUri}`,
  })
  const applyCurrent = jest.fn()
  const applyCached = jest.fn()

  const result = applyCreativeSaveResponse(
    snapshot,
    { markdown_source: 'before /blob/image' },
    {
      // The user dropped the uploaded image while the save was in flight, so
      // the substitution has nowhere to land in the live buffer.
      currentMarkdownSource: 'rewritten from scratch',
      applyCurrentMarkdownSource: applyCurrent,
      applyCachedMarkdownSource: applyCached,
    }
  )

  expect(applyCached).toHaveBeenCalledWith('before /blob/image', `before ${dataUri}`)
  expect(applyCurrent).not.toHaveBeenCalled()
  expect(result.snapshot).toBe(snapshot)
  expect(result.currentMarkdownSource).toBe('rewritten from scratch')
  expect(result.currentApplied).toBe(false)
})
