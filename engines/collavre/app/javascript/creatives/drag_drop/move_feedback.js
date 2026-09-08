import { MOVE_STATUSES } from './move_command';
import { alertDialog } from '../../lib/utils/dialog';

// A partial move leaves some rows where the user dropped them and some where
// they were. The trees still refresh, so without a notice the missing rows read
// as a rendering glitch rather than a rejected request.
export function reportPartialMove(result) {
  if (result?.status !== MOVE_STATUSES.PARTIAL) return false;

  const failures = Array.isArray(result.failures) ? result.failures : [];
  console.error('Creative move partially failed', {
    failedIds: result.failedIds,
    failures,
  });

  // The server phrases (and localizes) its own rejection; there is no
  // client-side copy to fall back on when it stays silent.
  const message = failures.map((failure) => failure?.message).find(Boolean);
  if (message) alertDialog(message);
  return true;
}
