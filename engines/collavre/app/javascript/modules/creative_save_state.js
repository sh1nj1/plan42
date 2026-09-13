import { isHtmlEmpty } from './html_content_empty'
import { isMarkdownEmpty } from './creative_row_editor_helpers'
import { reconcileMarkdownSource } from './markdown_source_reconcile'

function stringOrEmpty(value) {
  return value || ''
}

export function captureCreativeSaveSnapshot({
  content,
  emptyContent = content,
  emptyContentType = 'html',
  contentType = 'html',
  markdownSource = '',
  markdownEditor = '',
  progress = 0,
  persistProgress = false,
  creativeType,
  originId = '',
}) {
  return {
    content: stringOrEmpty(content),
    emptyContent: stringOrEmpty(emptyContent),
    emptyContentType,
    contentType,
    markdownSource: stringOrEmpty(markdownSource),
    markdownEditor: stringOrEmpty(markdownEditor),
    progress,
    persistProgress,
    originId: stringOrEmpty(originId),
    creativeType,
  }
}

export function captureDirectCreativeSaveSnapshot({
  markdownMode,
  markdownContent,
  htmlContent,
  contentType,
  markdownSource,
  markdownEditor,
  progress,
  persistProgress,
  originId,
  creativeType,
}) {
  return captureCreativeSaveSnapshot({
    content: markdownMode ? markdownContent : htmlContent,
    emptyContentType: markdownMode ? 'markdown' : 'html',
    contentType,
    markdownSource,
    markdownEditor,
    progress,
    persistProgress,
    originId,
    creativeType,
  })
}

export function captureQueuedCreativeSaveSnapshot({
  content,
  contentType,
  markdownSource,
  markdownEditor,
  progress,
  persistProgress,
  originId,
  creativeType,
}) {
  const isMarkdown = contentType === 'markdown'
  return captureCreativeSaveSnapshot({
    content,
    emptyContent: isMarkdown ? markdownSource : content,
    emptyContentType: isMarkdown ? 'markdown' : 'html',
    contentType,
    markdownSource: isMarkdown ? markdownSource : '',
    markdownEditor,
    progress,
    persistProgress,
    originId,
    creativeType,
  })
}

export function creativeSaveSnapshotIsEmpty(snapshot) {
  return snapshot.creativeType === undefined && (snapshot.emptyContentType === 'markdown'
    ? isMarkdownEmpty(snapshot.emptyContent)
    : isHtmlEmpty(snapshot.emptyContent))
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

export function resetCreativeSaveState(snapshot, current = null, currentDirty = false) {
  const matchesSnapshot = !current || (
    current.content === snapshot.content &&
    current.progress === snapshot.progress &&
    current.originId === snapshot.originId &&
    (snapshot.creativeType === undefined || current.creativeType === snapshot.creativeType)
  )

  return {
    originalContent: snapshot.content,
    originalProgress: snapshot.persistProgress ? snapshot.progress : undefined,
    originalOriginId: snapshot.originId,
    isDirty: matchesSnapshot ? false : currentDirty,
    pendingSave: false,
  }
}
