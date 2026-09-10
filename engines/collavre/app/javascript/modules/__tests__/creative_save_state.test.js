/**
 * @jest-environment jsdom
 */
import { jest } from '@jest/globals'
import {
  applyCreativeSaveResponse,
  captureCreativeSaveSnapshot,
  creativeSaveSnapshotIsEmpty,
  resetCreativeSaveState,
} from '../creative_save_state'

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

test('resets baselines and keeps a newer buffer dirty', () => {
  const snapshot = captureCreativeSaveSnapshot({
    content: 'saved', progress: 1, persistProgress: true, originId: '7',
  })

  expect(resetCreativeSaveState(snapshot, {
    content: 'newer', progress: 1, originId: '7',
  })).toEqual({
    originalContent: 'saved',
    originalProgress: 1,
    originalOriginId: '7',
    isDirty: true,
    pendingSave: false,
  })
  expect(resetCreativeSaveState(snapshot).isDirty).toBe(false)
})
