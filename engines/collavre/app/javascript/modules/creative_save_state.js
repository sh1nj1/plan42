import { isHtmlEmpty } from './html_content_empty'
import { isMarkdownEmpty } from './creative_row_editor_helpers'
import { reconcileMarkdownSource } from './markdown_source_reconcile'

export function captureCreativeSaveSnapshot({
  content,
  emptyContent = content,
  emptyContentType = 'html',
  contentType = 'html',
  markdownSource = '',
  markdownEditor = '',
  progress = 0,
  persistProgress = false,
  originId = '',
}) {
  return {
    content: content || '',
    emptyContent: emptyContent || '',
    emptyContentType,
    contentType,
    markdownSource: markdownSource || '',
    markdownEditor: markdownEditor || '',
    progress,
    persistProgress,
    originId: originId || '',
  }
}

export function creativeSaveSnapshotIsEmpty(snapshot) {
  return snapshot.emptyContentType === 'markdown'
    ? isMarkdownEmpty(snapshot.emptyContent)
    : isHtmlEmpty(snapshot.emptyContent)
}

export function applyCreativeSaveResponse(snapshot, data, {
  currentMarkdownSource,
  applyCurrentMarkdownSource,
  applyCachedMarkdownSource,
} = {}) {
  const serverSource = data?.markdown_source
  if (typeof serverSource !== 'string' || serverSource === snapshot.markdownSource) {
    return { snapshot, currentMarkdownSource, currentApplied: false }
  }

  applyCachedMarkdownSource?.(serverSource, snapshot.markdownSource)
  if (typeof currentMarkdownSource !== 'string') {
    return { snapshot, currentMarkdownSource, currentApplied: false }
  }

  const reconciled = reconcileMarkdownSource(
    snapshot.markdownSource, serverSource, currentMarkdownSource
  )
  if (reconciled === null) {
    return { snapshot, currentMarkdownSource, currentApplied: false }
  }

  if (reconciled !== currentMarkdownSource) applyCurrentMarkdownSource?.(reconciled)
  return {
    snapshot: {
      ...snapshot,
      content: snapshot.emptyContentType === 'markdown' ? serverSource : snapshot.content,
      emptyContent: snapshot.emptyContentType === 'markdown' ? serverSource : snapshot.emptyContent,
      markdownSource: serverSource,
    },
    currentMarkdownSource: reconciled,
    currentApplied: true,
  }
}

export function resetCreativeSaveState(snapshot, current = null) {
  const matchesSnapshot = !current || (
    current.content === snapshot.content &&
    current.progress === snapshot.progress &&
    current.originId === snapshot.originId
  )

  return {
    originalContent: snapshot.content,
    originalProgress: snapshot.persistProgress ? snapshot.progress : undefined,
    originalOriginId: snapshot.originId,
    isDirty: !matchesSnapshot,
    pendingSave: false,
  }
}
