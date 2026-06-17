import {
  detectDevice,
  shouldRun,
  buildCandidateList,
  anchorEdits,
  applyEditAt,
  shiftEditsAfter,
  partitionByThreshold,
  DEVICE_VOICE,
  DEVICE_SOFT_KEYBOARD,
  DEVICE_PHYSICAL_KEYBOARD,
} from '../typo_correction'

const settings = ({
  enabled = true,
  onVoice = true,
  onSoftKeyboard = true,
  onPhysicalKeyboard = false,
  inChat = true,
  inEditor = false,
} = {}) => ({ enabled, onVoice, onSoftKeyboard, onPhysicalKeyboard, inChat, inEditor })

describe('detectDevice', () => {
  test('voice recognition wins regardless of keyboard signals', () => {
    expect(detectDevice({ voiceActive: true, lastPrintableKeydownAt: 100, inputAt: 110 })).toBe(DEVICE_VOICE)
  })

  test('printable keydown right before input => physical keyboard', () => {
    expect(detectDevice({ lastPrintableKeydownAt: 1000, inputAt: 1005 })).toBe(DEVICE_PHYSICAL_KEYBOARD)
  })

  test('input with no preceding printable keydown => soft keyboard', () => {
    expect(detectDevice({ lastPrintableKeydownAt: null, inputAt: 1000 })).toBe(DEVICE_SOFT_KEYBOARD)
  })

  test('stale keydown (too far before input) => soft keyboard', () => {
    expect(detectDevice({ lastPrintableKeydownAt: 1000, inputAt: 2000 })).toBe(DEVICE_SOFT_KEYBOARD)
  })
})

describe('shouldRun (2D gating)', () => {
  test('runs when master + device + location all on', () => {
    expect(shouldRun(settings(), { device: DEVICE_SOFT_KEYBOARD, location: 'chat' })).toBe(true)
  })

  test('blocked when master off', () => {
    expect(shouldRun(settings({ enabled: false }), { device: DEVICE_SOFT_KEYBOARD, location: 'chat' })).toBe(false)
  })

  test('physical keyboard off by default blocks even in chat', () => {
    expect(shouldRun(settings(), { device: DEVICE_PHYSICAL_KEYBOARD, location: 'chat' })).toBe(false)
  })

  test('editor location off by default blocks even with soft keyboard', () => {
    expect(shouldRun(settings(), { device: DEVICE_SOFT_KEYBOARD, location: 'editor' })).toBe(false)
  })

  test('voice in chat runs', () => {
    expect(shouldRun(settings(), { device: DEVICE_VOICE, location: 'chat' })).toBe(true)
  })

  test('null settings never runs', () => {
    expect(shouldRun(null, { device: DEVICE_VOICE, location: 'chat' })).toBe(false)
  })
})

describe('buildCandidateList', () => {
  test('candidate state: original pre-filled, suggestions by confidence', () => {
    const list = buildCandidateList({
      currentValue: '안녀하세요',
      originalWord: '안녀하세요',
      suggestions: [
        { suggestion: '안녕하세요', confidence: 0.95 },
        { suggestion: '안녕하셔요', confidence: 0.4 },
      ],
    })
    expect(list.map((i) => i.value)).toEqual(['안녀하세요', '안녕하세요', '안녕하셔요'])
    expect(list[0].isCurrent).toBe(true)
    expect(list[0].role).toBe('original')
  })

  test('auto-applied state: corrected word current, original offered as undo', () => {
    const list = buildCandidateList({
      currentValue: '있습니다',
      originalWord: '잇습니다',
      suggestions: [{ suggestion: '있습니다', confidence: 0.99 }],
    })
    // current (applied) first, then original (undo); suggestion dupes current and is dropped.
    expect(list.map((i) => i.value)).toEqual(['있습니다', '잇습니다'])
    expect(list[0].role).toBe('applied')
    expect(list[0].isCurrent).toBe(true)
    expect(list[1].role).toBe('original')
  })

  test('de-duplicates and skips empties', () => {
    const list = buildCandidateList({
      currentValue: 'a',
      originalWord: 'a',
      suggestions: [{ suggestion: 'a' }, { suggestion: '' }, { suggestion: 'b', confidence: 0.5 }],
    })
    expect(list.map((i) => i.value)).toEqual(['a', 'b'])
  })
})

describe('anchorEdits', () => {
  test('binds offsets to substrings', () => {
    const text = '안녀하세요 저는 콜라브를 만들고 잇습니다'
    const edits = anchorEdits(text, [
      { original: '안녀하세요', suggestion: '안녕하세요' },
      { original: '잇습니다', suggestion: '있습니다' },
    ])
    expect(text.slice(edits[0].start, edits[0].end)).toBe('안녀하세요')
    expect(text.slice(edits[1].start, edits[1].end)).toBe('잇습니다')
  })

  test('repeated words anchor to distinct occurrences, not all to the first', () => {
    const text = 'teh cat and teh dog'
    const edits = anchorEdits(text, [
      { original: 'teh', suggestion: 'the' },
      { original: 'teh', suggestion: 'the' },
    ])
    expect(edits[0].start).toBe(0)
    expect(edits[1].start).toBe(12)
  })

  test('drops edits whose original is gone', () => {
    const edits = anchorEdits('hello world', [{ original: 'xyz', suggestion: 'abc' }])
    expect(edits).toEqual([])
  })
})

describe('applyEditAt + shiftEditsAfter (re-anchoring)', () => {
  test('applying one edit shifts the offsets of later edits', () => {
    let text = 'teh cat saw teh dog'
    const edits = anchorEdits(text, [
      { original: 'teh', suggestion: 'the' },
      { original: 'teh', suggestion: 'the' },
    ])
    const first = edits[0]
    const { text: t2, delta } = applyEditAt(text, { start: first.start, end: first.end, replacement: 'the' })
    text = t2
    expect(text).toBe('the cat saw teh dog')
    const remaining = shiftEditsAfter(edits.slice(1), first.start, delta)
    // 'the' and 'teh' are the same length here, delta 0; offset unchanged & still valid.
    expect(text.slice(remaining[0].start, remaining[0].end)).toBe('teh')
  })

  test('length-changing replacement re-anchors later edits correctly', () => {
    let text = 'a wrng word and anothr'
    const edits = anchorEdits(text, [
      { original: 'wrng', suggestion: 'wrong' },
      { original: 'anothr', suggestion: 'another' },
    ])
    const first = edits[0]
    const { text: t2, delta } = applyEditAt(text, { start: first.start, end: first.end, replacement: 'wrong' })
    text = t2
    expect(text).toBe('a wrong word and anothr')
    const remaining = shiftEditsAfter(edits.slice(1), first.start, delta)
    expect(text.slice(remaining[0].start, remaining[0].end)).toBe('anothr')
  })
})

describe('partitionByThreshold', () => {
  test('splits at/above vs below threshold', () => {
    const { autoApplied, candidates } = partitionByThreshold(
      [
        { original: 'a', confidence: 0.9 },
        { original: 'b', confidence: 0.8 },
        { original: 'c', confidence: 0.5 },
      ],
      80,
    )
    expect(autoApplied.map((e) => e.original)).toEqual(['a', 'b'])
    expect(candidates.map((e) => e.original)).toEqual(['c'])
  })
})
