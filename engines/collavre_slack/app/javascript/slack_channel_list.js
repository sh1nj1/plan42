/**
 * Pure-logic helpers for the Slack channel list.
 * Extracted so they can be unit-tested without a full DOM wizard.
 */

/**
 * Filter channels by a search query (case-insensitive substring match on name).
 * @param {Array<{id:string, name:string}>} channels
 * @param {string} query
 * @returns {Array<{id:string, name:string}>}
 */
export function filterChannels(channels, query) {
  const q = (query || '').toLowerCase();
  if (!q) return channels;
  return channels.filter(ch => ch.name.toLowerCase().includes(q));
}

/**
 * Decide whether selectedChannel should be cleared after a filter change.
 * Returns the selectedChannel as-is if it still exists in `filtered`,
 * or null if it has been filtered out.
 *
 * @param {{id:string, name:string}|null} selectedChannel
 * @param {Array<{id:string, name:string}>} filtered
 * @returns {{id:string, name:string}|null}
 */
export function reconcileSelection(selectedChannel, filtered) {
  if (!selectedChannel) return null;
  return filtered.some(ch => ch.id === selectedChannel.id) ? selectedChannel : null;
}

/**
 * Build the view-model array consumed by the DOM renderer.
 *
 * @param {Array<{id:string, name:string}>} channels   – filtered channel list
 * @param {Array<{channel_id:string}>}      links      – already-linked channels
 * @param {{id:string}|null}                selected   – currently selected channel
 * @returns {Array<{channel, isLinked:boolean, isSelected:boolean}>}
 */
export function buildChannelViewModels(channels, links, selected) {
  const linkedIds = new Set(links.map(l => l.channel_id));
  return channels.map(channel => ({
    channel,
    isLinked: linkedIds.has(channel.id),
    isSelected: selected !== null && selected.id === channel.id,
  }));
}
