import { renderMarkdownInContainer } from '../../lib/utils/markdown'

export function scrollToPreviousMessage() {
  const list = this.listTarget
  const elements = Array.from(list.querySelectorAll('.comment-item'))
  if (elements.length === 0) return

  const anchorId = this.prevMsgNavigator.anchorId
  const anchorIdx = anchorId === null
    ? -1
    : elements.findIndex((item) => item.dataset.commentId === anchorId)
  if (anchorIdx >= 0) {
	if (anchorIdx > 0) {
	  this.navigateToMessage(elements[anchorIdx - 1])
	  return
    }
    return this.loadAndNavigateToPreviousMessage(anchorId)
  }

  const viewportTop = list.getBoundingClientRect().top
  const measured = elements.map((el) => ({
    id: el.dataset.commentId,
    top: el.getBoundingClientRect().top,
  }))

  const targetIdx = this.prevMsgNavigator.resolveTargetIndex(measured, viewportTop)
  if (targetIdx < 0) {
    return this.loadAndNavigateToPreviousMessage(elements[0].dataset.commentId)
  }

  this.navigateToMessage(elements[targetIdx])
}

export function loadAndNavigateToPreviousMessage(anchorId) {
  if (this.navigateToPreviousSibling(anchorId)) return Promise.resolve(true)
  if (this.allOlderLoaded) return Promise.resolve(false)

  this.pendingPreviousMessageAnchorId = anchorId
  const requestContext = this.paginationRequestContext()
  return this.loadOlderComments().then(() => {
    if (!this.isCurrentPaginationContext(requestContext)) return false
    return this.fulfillPendingPreviousMessageNavigation()
  })
}

export function navigateToPreviousSibling(anchorId) {
  const comments = Array.from(this.listTarget.querySelectorAll('.comment-item'))
  const anchorIdx = comments.findIndex((item) => item.dataset.commentId === anchorId)
  if (anchorIdx <= 0) return false

  this.navigateToMessage(comments[anchorIdx - 1])
  return true
}

export function fulfillPendingPreviousMessageNavigation() {
  const anchorId = this.pendingPreviousMessageAnchorId
  if (!anchorId || !this.navigateToPreviousSibling(anchorId)) return false

  this.pendingPreviousMessageAnchorId = null
  return true
}

export function navigateToMessage(target) {
  const list = this.listTarget
  const targetTop = target.offsetTop - list.offsetTop
  this.prevMsgNavigator.commit(target.dataset.commentId, target.getBoundingClientRect().top)
  list.scrollTo({ top: targetTop, behavior: 'smooth' })
  this.stickToBottom = false

  target.classList.add('highlight-flash')
  target.dataset.highlighted = 'true'
  setTimeout(() => target.classList.remove('highlight-flash'), 2000)
}

export function loadOlderComments() {
  if (this.loadingOlder) return this.loadingOlderPromise || Promise.resolve(false)
  if (this.allOlderLoaded || !this.creativeId) return Promise.resolve(false)
  const minId = this.getMinId()
  if (!minId) return Promise.resolve(false)

  const requestContext = this.paginationRequestContext()
  this.loadingOlder = true

  // Standard Column: Older messages are at Top.
  // We Prepend them.
  const currentScrollHeight = this.listTarget.scrollHeight

  this.loadingOlderPromise = this.fetchComments({ before_id: minId }, { pagination: true })
    .then((html) => {
      if (!this.isCurrentPaginationContext(requestContext)) return false
      if (html.trim() === '') {
        this.allOlderLoaded = true
        return false
      }
      // Prepend to start (Visual Top)
      this.listTarget.insertAdjacentHTML('afterbegin', html)
      renderMarkdownInContainer(this.listTarget)
      const addedTopic = this.recordRenderedAllTopicWatermarks(
        this.listTarget.querySelectorAll('.comment-item'),
        { includeNewTopics: true },
      )
      if (addedTopic) this.reportRenderedAllTopics()
      this.markCommentsRead()

      // Restore scroll position
      const newScrollHeight = this.listTarget.scrollHeight
      this.listTarget.scrollTop = this.listTarget.scrollTop + (newScrollHeight - currentScrollHeight)

	// Prepending changes element geometry without user input. Keep the
	// previous-message anchor based on its new position so the next click
	// continues into the newly loaded page instead of dropping the anchor.
	const anchorId = this.prevMsgNavigator.anchorId
	const anchor = anchorId && Array.from(this.listTarget.querySelectorAll('.comment-item'))
	  .find((item) => item.dataset.commentId === anchorId)
	if (anchor) this.prevMsgNavigator.commit(anchorId, anchor.getBoundingClientRect().top)

	this.fulfillPendingPreviousMessageNavigation()

	return true
    })
    .finally(() => {
      if (this.isCurrentPaginationContext(requestContext)) {
        this.loadingOlder = false
        this.loadingOlderPromise = null
      }
    })

  return this.loadingOlderPromise
}
