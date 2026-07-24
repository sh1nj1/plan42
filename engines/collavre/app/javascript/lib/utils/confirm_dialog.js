/**
 * confirm_dialog — backwards-compatible entry point.
 *
 * The implementation now lives in ./dialog.js alongside alertDialog and
 * promptDialog, which share one modal core. This module is kept so existing
 * `import { confirmDialog } from '.../confirm_dialog'` call sites (and their
 * tests) keep working. New code should import from './dialog' to also reach
 * alertDialog / promptDialog.
 */
export { confirmDialog, default } from './dialog'
