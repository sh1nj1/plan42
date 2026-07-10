/**
 * Pure-logic helpers for the GitHub integration wizard's connect step.
 * Extracted so the "can this user advance past the connect step" decision
 * can be unit-tested without the full DOM wizard.
 */

/**
 * Derive connect-step flags from the integration status payload.
 *
 * `userConnected` reflects whether the *current* user has their own linked
 * GitHub account. `hasExistingIntegration` reflects whether the creative
 * already has repositories linked — by this user when connected, or by *any*
 * member (all_repositories) when the current user is not yet connected.
 *
 * @param {{connected?:boolean, all_repositories?:string[], selected_repositories?:string[]}} status
 * @returns {{userConnected:boolean, hasExistingIntegration:boolean}}
 */
export function deriveConnectState(status) {
  const s = status || {};
  const userConnected = !!s.connected;
  const repos = userConnected ? s.selected_repositories : s.all_repositories;
  const hasExistingIntegration = (repos || []).length > 0;
  return { userConnected, hasExistingIntegration };
}

/**
 * Whether the connect step's "Next" button should be shown.
 *
 * Existing repositories linked by *other* members must not let an
 * unauthenticated user advance: organization lookup requires the user's own
 * connected GitHub account, so advancing would dead-end on an empty
 * organization list ("조회할 수 있는 Organization이 없습니다."). Such a user
 * must log in first.
 *
 * @param {{hasExistingIntegration?:boolean, userConnected?:boolean}} state
 * @returns {boolean}
 */
export function shouldShowConnectNext(state) {
  const s = state || {};
  return !!(s.hasExistingIntegration && s.userConnected);
}
