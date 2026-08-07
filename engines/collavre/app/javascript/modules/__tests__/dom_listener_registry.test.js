/**
 * @jest-environment jsdom
 */
import { jest } from '@jest/globals';
import { createListenerRegistry } from '../dom_listener_registry';

describe('createListenerRegistry', () => {
  test('releases every registered listener', () => {
    const registry = createListenerRegistry();
    const documentHandler = jest.fn();
    const windowHandler = jest.fn();
    registry.add(document, 'registry-document', documentHandler);
    registry.add(window, 'registry-window', windowHandler);

    registry.releaseAll();
    document.dispatchEvent(new Event('registry-document'));
    window.dispatchEvent(new Event('registry-window'));

    expect(documentHandler).not.toHaveBeenCalled();
    expect(windowHandler).not.toHaveBeenCalled();
    expect(registry.size).toBe(0);
  });

  test('rebinds a Turbo session without retaining the old handler', () => {
    const registry = createListenerRegistry();
    const firstSession = jest.fn();
    const secondSession = jest.fn();
    registry.add(document.body, 'click', firstSession);

    registry.releaseAll();
    registry.add(document.body, 'click', secondSession);
    document.body.click();

    expect(firstSession).not.toHaveBeenCalled();
    expect(secondSession).toHaveBeenCalledTimes(1);
    registry.releaseAll();
  });

  test('preserves listener options when removing a binding', () => {
    const registry = createListenerRegistry();
    const handler = jest.fn();
    registry.add(document, 'registry-capture', handler, { capture: true });

    registry.releaseAll();
    document.dispatchEvent(new Event('registry-capture'));

    expect(handler).not.toHaveBeenCalled();
  });

  test('ignores targets that cannot register listeners', () => {
    const registry = createListenerRegistry();

    expect(() => registry.add(null, 'click', jest.fn())).not.toThrow();
    expect(() => registry.add({}, 'click', jest.fn())).not.toThrow();
    expect(registry.size).toBe(0);
  });

  test('releaseAll is idempotent', () => {
    const registry = createListenerRegistry();
    registry.add(document, 'registry-idempotent', jest.fn());

    registry.releaseAll();

    expect(() => registry.releaseAll()).not.toThrow();
    expect(registry.size).toBe(0);
  });
});
