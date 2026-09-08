import { MOVE_STATUSES } from './move_command';
import { alertDialog } from '../../lib/utils/dialog';

// A partial move leaves some rows where the user dropped them and some where
// they were. The trees still refresh, so without a notice the missing rows read
// as a rendering glitch rather than a rejected request.
export function reportPartialMove(result, fallbackMessage = '') {
  if (result?.status !== MOVE_STATUSES.PARTIAL) return false;

  const failures = Array.isArray(result.failures) ? result.failures : [];
  console.error('Creative move partially failed', {
    failedIds: result.failedIds,
    failures,
  });

  // Only errors parsed from a server payload are safe to present verbatim.
  // Transport/status messages such as "HTTP 403: Forbidden" are diagnostic
  // English and must not bypass the page's translated fallback.
  const message = failures.map((failure) => failure?.serverMessage).find(Boolean)
    || fallbackMessage;
  if (message) alertDialog(message);
  return true;
}
