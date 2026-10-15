export async function initializePdfDocument(viewer, load = () => import('pdfjs-dist')) {
  const content = viewer.querySelector('[data-pdf-src]')
  if (!content) return
  const loading = viewer.querySelector('.media-loading')
  let pageNumber = 1
  let scale = 1
  let rendering = false
  let renderPending = false
  try {
    const { getDocument, GlobalWorkerOptions } = await load()
    GlobalWorkerOptions.workerSrc = content.dataset.pdfWorker
    const pdf = await getDocument({ url: content.dataset.pdfSrc }).promise
    async function show() {
      if (rendering) { renderPending = true; return }
      renderPending = false
      rendering = true
      loading.hidden = false
      updatePdfControls(viewer, pageNumber, pdf.numPages)
      try {
        const page = await pdf.getPage(pageNumber)
        const base = page.getViewport({ scale: 1 })
        const viewport = page.getViewport({ scale: Math.min(content.clientWidth / base.width, 4) * scale })
        const canvas = document.createElement('canvas')
        canvas.width = viewport.width
        canvas.height = viewport.height
        await page.render({ canvasContext: canvas.getContext('2d'), viewport }).promise
        viewer.querySelector('[data-document-error]').hidden = true
        content.replaceChildren(canvas)
      } finally {
        loading.hidden = true
        rendering = false
        if (renderPending) await show()
      }
    }
    bindPdfControls(viewer, {
      previous: () => { if (!rendering && pageNumber > 1) { pageNumber--; show().catch(failed) } },
      next: () => { if (!rendering && pageNumber < pdf.numPages) { pageNumber++; show().catch(failed) } },
      zoom: () => { if (!rendering) { scale = scale === 1 ? 1.5 : 1; show().catch(failed) } },
    })
    viewer.ownerDocument.defaultView.addEventListener("resize", () => show().catch(failed))
    await show()
  } catch { failed() }

  function failed() {
    loading.hidden = true
    viewer.querySelector('[data-document-error]').hidden = false
  }
}

function bindPdfControls(viewer, actions) {
  viewer.querySelector('[data-ppt-previous]').addEventListener('click', actions.previous)
  viewer.querySelector('[data-ppt-next]').addEventListener('click', actions.next)
  viewer.querySelector('[data-pdf-zoom]').addEventListener('click', actions.zoom)
}

function updatePdfControls(viewer, pageNumber, pageCount) {
  viewer.querySelector('[data-ppt-counter]').textContent = `${pageNumber} / ${pageCount}`
  viewer.querySelector('[data-ppt-previous]').disabled = pageNumber === 1
  viewer.querySelector('[data-ppt-next]').disabled = pageNumber === pageCount
}
