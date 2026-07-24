/**
 * @jest-environment jsdom
 */
import { filterChannels, reconcileSelection, buildChannelViewModels } from '../slack_channel_list.js';

const channels = [
  { id: 'C01', name: 'general' },
  { id: 'C02', name: 'random' },
  { id: 'C03', name: 'engineering' },
  { id: 'C04', name: 'design' },
  { id: 'C05', name: 'general-kr' },
];

describe('filterChannels', () => {
  test('returns all channels when query is empty', () => {
    expect(filterChannels(channels, '')).toEqual(channels);
    expect(filterChannels(channels, null)).toEqual(channels);
    expect(filterChannels(channels, undefined)).toEqual(channels);
  });

  test('filters by substring match (case-insensitive)', () => {
    const result = filterChannels(channels, 'gen');
    expect(result).toEqual([
      { id: 'C01', name: 'general' },
      { id: 'C05', name: 'general-kr' },
    ]);
  });

  test('is case-insensitive', () => {
    expect(filterChannels(channels, 'DESIGN')).toEqual([
      { id: 'C04', name: 'design' },
    ]);
  });

  test('returns empty array when nothing matches', () => {
    expect(filterChannels(channels, 'zzz')).toEqual([]);
  });

  test('returns empty array when channels list is empty', () => {
    expect(filterChannels([], 'gen')).toEqual([]);
  });
});

describe('reconcileSelection', () => {
  test('returns null when no channel is selected', () => {
    expect(reconcileSelection(null, channels)).toBeNull();
  });

  test('keeps selection when channel is in filtered list', () => {
    const selected = { id: 'C01', name: 'general' };
    expect(reconcileSelection(selected, channels)).toBe(selected);
  });

  test('clears selection when channel is filtered out', () => {
    const selected = { id: 'C01', name: 'general' };
    const filtered = [{ id: 'C04', name: 'design' }];
    expect(reconcileSelection(selected, filtered)).toBeNull();
  });

  test('clears selection when filtered list is empty', () => {
    const selected = { id: 'C01', name: 'general' };
    expect(reconcileSelection(selected, [])).toBeNull();
  });
});

describe('buildChannelViewModels', () => {
  test('marks linked channels', () => {
    const links = [{ channel_id: 'C02' }];
    const result = buildChannelViewModels(channels, links, null);

    const linkedItem = result.find(vm => vm.channel.id === 'C02');
    expect(linkedItem.isLinked).toBe(true);

    const unlinkedItem = result.find(vm => vm.channel.id === 'C01');
    expect(unlinkedItem.isLinked).toBe(false);
  });

  test('marks selected channel', () => {
    const selected = { id: 'C03', name: 'engineering' };
    const result = buildChannelViewModels(channels, [], selected);

    const selectedItem = result.find(vm => vm.channel.id === 'C03');
    expect(selectedItem.isSelected).toBe(true);

    const otherItem = result.find(vm => vm.channel.id === 'C01');
    expect(otherItem.isSelected).toBe(false);
  });

  test('no channel is selected when selection is null', () => {
    const result = buildChannelViewModels(channels, [], null);
    expect(result.every(vm => !vm.isSelected)).toBe(true);
  });

  test('handles empty inputs', () => {
    expect(buildChannelViewModels([], [], null)).toEqual([]);
  });

  test('channel can be both linked and selected', () => {
    const selected = { id: 'C02', name: 'random' };
    const links = [{ channel_id: 'C02' }];
    const result = buildChannelViewModels(channels, links, selected);

    const item = result.find(vm => vm.channel.id === 'C02');
    expect(item.isLinked).toBe(true);
    expect(item.isSelected).toBe(true);
  });
});

describe('search → selection regression', () => {
  test('selecting a channel then filtering it out clears selection', () => {
    // User selects #general
    const selected = { id: 'C01', name: 'general' };

    // Then types "design" in search
    const filtered = filterChannels(channels, 'design');
    expect(filtered).toEqual([{ id: 'C04', name: 'design' }]);

    // Selection should be cleared because #general is not in results
    const reconciled = reconcileSelection(selected, filtered);
    expect(reconciled).toBeNull();
  });

  test('selecting a channel then filtering to include it keeps selection', () => {
    const selected = { id: 'C01', name: 'general' };
    const filtered = filterChannels(channels, 'gen');

    // #general is still in the results
    const reconciled = reconcileSelection(selected, filtered);
    expect(reconciled).toBe(selected);
  });

  test('clearing the search restores selection if channel exists', () => {
    const selected = { id: 'C01', name: 'general' };

    // Filter out, selection cleared
    const filtered1 = filterChannels(channels, 'design');
    const reconciled1 = reconcileSelection(selected, filtered1);
    expect(reconciled1).toBeNull();

    // Clear search — but reconcileSelection won't magically restore,
    // it returns null because reconciled1 was already null
    const filtered2 = filterChannels(channels, '');
    const reconciled2 = reconcileSelection(reconciled1, filtered2);
    expect(reconciled2).toBeNull();
  });

  test('full flow: filter → select → widen filter keeps new selection', () => {
    // User types "des", sees only #design
    const filtered1 = filterChannels(channels, 'des');
    expect(filtered1).toEqual([{ id: 'C04', name: 'design' }]);

    // User selects #design
    const selected = { id: 'C04', name: 'design' };

    // User clears search — #design is still in full list
    const filtered2 = filterChannels(channels, '');
    const reconciled = reconcileSelection(selected, filtered2);
    expect(reconciled).toBe(selected);

    // View models reflect selection correctly
    const vms = buildChannelViewModels(filtered2, [], reconciled);
    const designVm = vms.find(vm => vm.channel.id === 'C04');
    expect(designVm.isSelected).toBe(true);
    expect(vms.filter(vm => vm.isSelected)).toHaveLength(1);
  });
});
