import { buildFlatText, locateOffset, mapRange } from '../lexical_typo_text'

describe('buildFlatText', () => {
  it('concatenates segments and records keyed offsets', () => {
    const { text, map } = buildFlatText([
      { key: 'a', text: 'hello ' },
      { key: 'b', text: 'wrold' },
    ])
    expect(text).toBe('hello wrold')
    expect(map).toEqual([
      { key: 'a', start: 0, end: 6 },
      { key: 'b', start: 6, end: 11 },
    ])
  })

  it('advances offset for keyless separators without mapping them', () => {
    const { text, map } = buildFlatText([
      { key: 'a', text: 'one' },
      { key: null, text: '\n' },
      { key: 'b', text: 'two' },
    ])
    expect(text).toBe('one\ntwo')
    expect(map).toEqual([
      { key: 'a', start: 0, end: 3 },
      { key: 'b', start: 4, end: 7 },
    ])
  })

  it('ignores malformed segments', () => {
    const { text, map } = buildFlatText([null, { key: 'a' }, { key: 'b', text: 'x' }])
    expect(text).toBe('x')
    expect(map).toEqual([{ key: 'b', start: 0, end: 1 }])
  })
})

describe('locateOffset', () => {
  const { map } = buildFlatText([
    { key: 'a', text: 'one' },
    { key: null, text: '\n' },
    { key: 'b', text: 'two' },
  ])

  it('locates an offset inside a segment', () => {
    expect(locateOffset(map, 1)).toEqual({ key: 'a', localOffset: 1 })
    expect(locateOffset(map, 5)).toEqual({ key: 'b', localOffset: 1 })
  })

  it('binds an end-of-segment offset to the next abutting segment', () => {
    const abut = buildFlatText([
      { key: 'a', text: 'foo' },
      { key: 'b', text: 'bar' },
    ]).map
    expect(locateOffset(abut, 3)).toEqual({ key: 'b', localOffset: 0 })
  })

  it('clamps to the last segment end when nothing abuts', () => {
    expect(locateOffset(map, 7)).toEqual({ key: 'b', localOffset: 3 })
  })

  it('returns null for an offset over a gap (separator) or empty map', () => {
    expect(locateOffset(map, 3)).toEqual({ key: 'a', localOffset: 3 }) // end of 'a', gap follows (no abut)
    expect(locateOffset([], 0)).toBeNull()
  })
})

describe('mapRange', () => {
  it('maps a range fully inside one segment', () => {
    const { map } = buildFlatText([{ key: 'a', text: 'hello wrold' }])
    expect(mapRange(map, 6, 11)).toEqual([{ key: 'a', localStart: 6, localEnd: 11 }])
  })

  it('splits a range that spans multiple segments', () => {
    const { map } = buildFlatText([
      { key: 'a', text: 'foo' },
      { key: 'b', text: 'bar' },
    ])
    expect(mapRange(map, 2, 5)).toEqual([
      { key: 'a', localStart: 2, localEnd: 3 },
      { key: 'b', localStart: 0, localEnd: 2 },
    ])
  })

  it('skips keyless separator gaps in the covered range', () => {
    const { map } = buildFlatText([
      { key: 'a', text: 'foo' },
      { key: null, text: '\n' },
      { key: 'b', text: 'bar' },
    ])
    // range 2..6 covers 'o' of foo, the '\n' gap, and 'ba' of bar
    expect(mapRange(map, 2, 6)).toEqual([
      { key: 'a', localStart: 2, localEnd: 3 },
      { key: 'b', localStart: 0, localEnd: 2 },
    ])
  })

  it('returns [] for empty or inverted ranges', () => {
    const { map } = buildFlatText([{ key: 'a', text: 'foo' }])
    expect(mapRange(map, 2, 2)).toEqual([])
    expect(mapRange(map, 3, 1)).toEqual([])
  })
})
