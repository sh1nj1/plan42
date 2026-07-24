import { deriveConnectState, shouldShowConnectNext } from '../github_wizard_state.js';

describe('deriveConnectState', () => {
  test('connected user with selected repos: connected + existing', () => {
    expect(deriveConnectState({ connected: true, selected_repositories: ['a/b'] }))
      .toEqual({ userConnected: true, hasExistingIntegration: true });
  });

  test('connected user with no selected repos: connected, no existing', () => {
    expect(deriveConnectState({ connected: true, selected_repositories: [] }))
      .toEqual({ userConnected: true, hasExistingIntegration: false });
  });

  test('connected user ignores all_repositories for existing flag', () => {
    // A connected user's existing state comes from their own selection,
    // never from other members' all_repositories.
    expect(deriveConnectState({ connected: true, selected_repositories: [], all_repositories: ['x/y', 'x/z'] }))
      .toEqual({ userConnected: true, hasExistingIntegration: false });
  });

  test('unconnected user with repos linked by others: not connected but existing', () => {
    expect(deriveConnectState({ connected: false, all_repositories: ['x/y', 'x/z', 'x/w'] }))
      .toEqual({ userConnected: false, hasExistingIntegration: true });
  });

  test('unconnected user with no repos: not connected, no existing', () => {
    expect(deriveConnectState({ connected: false, all_repositories: [] }))
      .toEqual({ userConnected: false, hasExistingIntegration: false });
  });

  test('tolerates missing/empty payload', () => {
    expect(deriveConnectState()).toEqual({ userConnected: false, hasExistingIntegration: false });
    expect(deriveConnectState({})).toEqual({ userConnected: false, hasExistingIntegration: false });
  });
});

describe('shouldShowConnectNext', () => {
  test('shows Next only when the current user is connected AND repos exist', () => {
    expect(shouldShowConnectNext({ hasExistingIntegration: true, userConnected: true })).toBe(true);
  });

  test('hides Next for an unconnected user even when repos exist (regression)', () => {
    // Repos linked by other members must not let an unauthenticated user
    // advance into an empty organization list — they must log in first.
    expect(shouldShowConnectNext({ hasExistingIntegration: true, userConnected: false })).toBe(false);
  });

  test('hides Next when there is no existing integration', () => {
    expect(shouldShowConnectNext({ hasExistingIntegration: false, userConnected: true })).toBe(false);
    expect(shouldShowConnectNext({ hasExistingIntegration: false, userConnected: false })).toBe(false);
  });

  test('tolerates missing state', () => {
    expect(shouldShowConnectNext()).toBe(false);
    expect(shouldShowConnectNext({})).toBe(false);
  });
});
