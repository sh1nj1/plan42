/**
 * @jest-environment jsdom
 */
import { isProgressComplete, progressBaselineValueFrom, progressValueChangedFrom } from '../creative_progress';

describe('creative progress helpers', () => {
  describe('isProgressComplete', () => {
    test('returns true for values >= 1', () => {
      expect(isProgressComplete(1)).toBe(true);
      expect(isProgressComplete(1.0)).toBe(true);
      expect(isProgressComplete(1.5)).toBe(true);
    });

    test('returns false for values < 1', () => {
      expect(isProgressComplete(0)).toBe(false);
      expect(isProgressComplete(0.5)).toBe(false);
      expect(isProgressComplete(0.99)).toBe(false);
    });

    test('returns false for NaN values', () => {
      expect(isProgressComplete(NaN)).toBe(false);
      expect(isProgressComplete('invalid')).toBe(false);
    });
  });

  describe('progressBaselineValueFrom', () => {
    test('returns 1 for complete values', () => {
      expect(progressBaselineValueFrom(1)).toBe(1);
      expect(progressBaselineValueFrom(1.5)).toBe(1);
    });

    test('returns 0 for incomplete values', () => {
      expect(progressBaselineValueFrom(0)).toBe(0);
      expect(progressBaselineValueFrom(0.4)).toBe(0);
      expect(progressBaselineValueFrom(0.99)).toBe(0);
    });
  });

  describe('progressValueChangedFrom', () => {
    test('preserves fractional values unless checkbox toggled', () => {
      expect(progressValueChangedFrom(0.4, false)).toBe(false);
      expect(progressValueChangedFrom(0.4, true)).toBe(true);
    });

    test('detects change from complete to incomplete', () => {
      expect(progressValueChangedFrom(1, false)).toBe(true);
      expect(progressValueChangedFrom(1, true)).toBe(false);
    });
  });
});
