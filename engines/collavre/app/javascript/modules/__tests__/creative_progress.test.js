/**
 * @jest-environment jsdom
 */
import { progressBaselineValueFrom, progressValueChangedFrom } from '../creative_progress';

describe('creative progress helpers', () => {
  test('progressValueChangedFrom preserves fractional values unless checkbox toggled', () => {
    expect(progressBaselineValueFrom(0.4)).toBe(0);
    expect(progressValueChangedFrom(0.4, false)).toBe(false);
    expect(progressValueChangedFrom(0.4, true)).toBe(true);
  });
});
