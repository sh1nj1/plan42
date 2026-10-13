/** @jest-environment jsdom */
import { jest } from '@jest/globals'
import { refreshFilteredProgress } from '../creative_tree_invalidation'

test.each([
  ['/creatives?tags%5B%5D=7&min_progress=1', 1],
  ['/creatives?tags=7', 1],
  ['/creatives?tags%5B%5D=&tags%5B%5D=7', 1],
  ['/creatives?tags%5B%5D=', 0],
  ['/creatives?search=hello', 0],
])('uses current tree URL even with stale row attributes (%s)', (url, count) => {
  document.body.innerHTML = '<div data-creatives--tree-url-value=""></div><creative-tree-row data-display-progress="0"></creative-tree-row>'
  document.querySelector('div').setAttribute('data-creatives--tree-url-value', url)
  const refetch = jest.fn()
  document.addEventListener('creative-sync:refetch', refetch)
  try {
    refreshFilteredProgress()
    expect(refetch).toHaveBeenCalledTimes(count)
  } finally {
    document.removeEventListener('creative-sync:refetch', refetch)
    document.body.innerHTML = ''
  }
})
