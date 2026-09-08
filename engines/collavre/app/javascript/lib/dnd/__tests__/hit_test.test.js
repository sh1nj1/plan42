import {
  DEFAULT_CHILD_ZONE_RATIO,
  DEFAULT_HYSTERESIS_RATIO,
  DEFAULT_MIN_HYSTERESIS,
  getVerticalDropPosition,
} from '../hit_test';

const rect = { top: 100, height: 100 };

test('uses strict 0.3 child-zone boundaries', () => {
  expect(DEFAULT_CHILD_ZONE_RATIO).toBe(0.3);
  expect(getVerticalDropPosition({ clientY: 129.9, rect })).toBe('up');
  expect(getVerticalDropPosition({ clientY: 130, rect })).toBe('child');
  expect(getVerticalDropPosition({ clientY: 170, rect })).toBe('child');
  expect(getVerticalDropPosition({ clientY: 170.1, rect })).toBe('down');
});

test('keeps the previous position inside the hysteresis buffer', () => {
  expect(DEFAULT_HYSTERESIS_RATIO).toBe(0.12);
  expect(DEFAULT_MIN_HYSTERESIS).toBe(12);

  expect(getVerticalDropPosition({ clientY: 141.9, rect, previousPosition: 'up' }))
    .toBe('up');
  expect(getVerticalDropPosition({ clientY: 142, rect, previousPosition: 'up' }))
    .toBe('child');

  expect(getVerticalDropPosition({ clientY: 117.9, rect, previousPosition: 'child' }))
    .toBe('up');
  expect(getVerticalDropPosition({ clientY: 118, rect, previousPosition: 'child' }))
    .toBe('child');
  expect(getVerticalDropPosition({ clientY: 182, rect, previousPosition: 'child' }))
    .toBe('child');
  expect(getVerticalDropPosition({ clientY: 182.1, rect, previousPosition: 'child' }))
    .toBe('down');

  expect(getVerticalDropPosition({ clientY: 158, rect, previousPosition: 'down' }))
    .toBe('child');
  expect(getVerticalDropPosition({ clientY: 158.1, rect, previousPosition: 'down' }))
    .toBe('down');
});

test('supports explicit ratios and validates geometry', () => {
  expect(getVerticalDropPosition({
    clientY: 40,
    rect: { top: 0, height: 200 },
    childZoneRatio: 0.25,
    hysteresisRatio: 0.2,
    minHysteresis: 0,
    previousPosition: 'up',
  })).toBe('up');

  expect(getVerticalDropPosition({ clientY: Number.NaN, rect })).toBeNull();
  expect(getVerticalDropPosition({ clientY: 1, rect: null })).toBeNull();
  expect(getVerticalDropPosition({ clientY: 1, rect: { top: 0, height: 0 } }))
    .toBeNull();
  expect(getVerticalDropPosition({ clientY: 1, rect: { top: 'bad', height: 10 } }))
    .toBeNull();
});
