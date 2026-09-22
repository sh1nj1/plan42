/** @jest-environment jsdom */
import { rememberRecoveredPosition, queuedCreativePosition, rememberAcknowledgedPosition, withAcknowledgedParent } from '../recovered_creative_position'

function row(id) {
  const tree = document.createElement('div')
  tree.dataset.id = id
  return tree
}

test('uses DOM position normally and honors a new move after restoration', () => {
  const tree = row('42')
  const container = document.createElement('div')
  container.append(row('41'), tree, row('43'))
  tree.dataset.parentId = '10'
  expect(queuedCreativePosition(tree)).toEqual({ 'creative[parent_id]': '10', before_id: '41', after_id: '43' })
  rememberRecoveredPosition(tree, { 'creative[parent_id]': '99', before_id: '100' })
  expect(queuedCreativePosition(tree)).toEqual({ 'creative[parent_id]': '99', before_id: '100', after_id: '' })
  tree.dataset.parentId = '20'
  expect(queuedCreativePosition(tree)['creative[parent_id]']).toBe('20')
  tree.dataset.parentId = '10'
  container.append(tree)
  expect(queuedCreativePosition(tree).before_id).toBe('43')
})

test('clears recovery on reopen without a pending structural change', () => {
  const tree = row('42')
  rememberRecoveredPosition(tree, { 'creative[parent_id]': '', after_id: '100' })
  expect(queuedCreativePosition(tree)).toEqual({ 'creative[parent_id]': '', before_id: '', after_id: '100' })
  rememberRecoveredPosition(tree)
  expect(queuedCreativePosition(tree)).toEqual({ 'creative[parent_id]': '', before_id: '', after_id: '' })
})


test('acknowledged positions survive reopening, while pending and explicit moves take precedence', () => {
  const tree = row('42')
  tree.dataset.parentId = '10'
  const data = { parent_id: 20 }
  rememberAcknowledgedPosition(tree, data)
  rememberRecoveredPosition(tree)
  expect(queuedCreativePosition(tree)).toEqual({ 'creative[parent_id]': 20 })
  expect(withAcknowledgedParent(tree, { parent_id: 10 })).toEqual(data)
  rememberRecoveredPosition(tree, { 'creative[parent_id]': '30', after_id: '31' })
  expect(queuedCreativePosition(tree)).toEqual({ 'creative[parent_id]': '30', before_id: '', after_id: '31' })
  tree.dataset.parentId = '40'
  expect(queuedCreativePosition(tree)).toEqual({ 'creative[parent_id]': '40', before_id: '', after_id: '' })
  expect(withAcknowledgedParent(tree, data)).toBe(data)
})

test('ignores payloads without a parent and preserves acknowledged root moves', () => {
  const tree = row('42')
  tree.dataset.parentId = '10'
  rememberAcknowledgedPosition(tree, {})
  expect(queuedCreativePosition(tree)['creative[parent_id]']).toBe('10')
  rememberAcknowledgedPosition(tree, { parent_id: null })
  expect(queuedCreativePosition(tree)).toEqual({ 'creative[parent_id]': '' })
  expect(withAcknowledgedParent(tree, { parent_id: 10 }).parent_id).toBe('')
})
