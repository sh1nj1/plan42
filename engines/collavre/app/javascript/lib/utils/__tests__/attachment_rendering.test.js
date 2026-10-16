import { computeAccessibleName } from 'dom-accessibility-api'
import { renderToStaticMarkup } from 'react-dom/server'
import { createEditor } from 'lexical'
import { AttachmentNode, $createAttachmentNode } from '../../lexical/attachment_node'
import { attachmentLinkParts } from '../../lexical/attachment_presentation'
import { sanitizeDescriptionHtml } from '../sanitize_description'

function render(html) {
  const container = document.createElement('div')
  container.innerHTML = sanitizeDescriptionHtml(html)
  return container
}

describe('attachment rendering parity', () => {
  beforeEach(() => {
    globalThis.HTMLAnchorElement = window.HTMLAnchorElement
    Object.defineProperty(window.HTMLIFrameElement.prototype, 'allow', {
      configurable: true,
      get() { return this.getAttribute('allow') },
      set(value) { this.setAttribute('allow', value) },
    })
    document.head.innerHTML = '<meta name="ppt-preview-url-template" content="/ppt_previews/PPT_BLOB_ID">'
  })

  test.each(['/rails/active_storage/blobs/redirect/signed/deck.pptx', '/collavre/public-assets/blobs/signed/deck.pptx'])(
    'preserves the server-provided engine mount path in both display paths: %s', src => {
      document.querySelector('meta[name="ppt-preview-url-template"]').content = '/collavre/ppt_previews/PPT_BLOB_ID'
      const editor = createEditor({nodes: [AttachmentNode], onError: error => { throw error }})
      editor.update(() => {
	const node = $createAttachmentNode({src, filename: 'deck.pptx'})
	const saved = render(node.exportDOM().element.outerHTML).querySelector('iframe')
	const editing = document.createElement('div')
	editing.innerHTML = renderToStaticMarkup(node.decorate())
	expect(saved.getAttribute('src')).toBe('/collavre/ppt_previews/signed')
	expect(sanitizeDescriptionHtml(saved.outerHTML)).toContain('/collavre/ppt_previews/signed')
	expect(editing.querySelector('iframe').getAttribute('src')).toBe(saved.getAttribute('src'))
      }, {discrete: true})
    }
  )

  test.each(['/\\evil.example/ppt_previews/signed', '/\n/evil.example/ppt_previews/signed'])(
    'rejects iframe URLs that browsers normalize to external origins: %s', src => {
      const frame = document.createElement('iframe')
      frame.setAttribute('src', src)
      expect(render(frame.outerHTML).querySelector('iframe')).toBeNull()
    }
  )

  test('keeps a download link when the server route template is unavailable', () => {
    document.head.innerHTML = ''
    expect(render('<a download="deck.pptx" href="/public-assets/blobs/signed/deck.pptx">deck.pptx</a>').querySelector('iframe')).toBeNull()
  })

  test('renders the same attachment contents and class as the editor', () => {
    const editor = createEditor({nodes: [AttachmentNode], onError: error => { throw error }})
    editor.update(() => {
      const node = $createAttachmentNode({src: '/file', filename: 'slides.pptx', filesize: 2048})
      const saved = render(node.exportDOM().element.outerHTML).querySelector('a')
      const editing = document.createElement('div')
      editing.innerHTML = renderToStaticMarkup(node.decorate())
      expect(computeAccessibleName(saved)).toBe('slides.pptx (2 KB)')
      expect(computeAccessibleName(editing.firstChild)).toBe('slides.pptx (2 KB)')
      expect(saved.textContent).toBe('slides.pptx')
      expect(editing.firstChild.textContent).toBe('slides.pptx')
      expect(saved.innerHTML).toBe(editing.firstChild.innerHTML)
      expect(saved.className).toBe(editing.firstChild.className)
      expect(saved.getAttribute('href')).toBe(editing.firstChild.getAttribute('href'))
      expect(saved.getAttribute('download')).toBe(editing.firstChild.getAttribute('download'))
    }, {discrete: true})
  })

  test.each([
    '/rails/active_storage/blobs/redirect/signed/deck.pptx',
    '/rails/active_storage/blobs/proxy/signed/deck.pptx',
    '/public-assets/blobs/signed/deck.pptx',
    'https://assets.example.com/public-assets/blobs/signed/deck.pptx',
  ])('PPT previews match in editor and saved descriptions: %s', src => {
    const editor = createEditor({nodes: [AttachmentNode], onError: error => { throw error }})
    editor.update(() => {
      const node = $createAttachmentNode({src, filename: 'deck.PPTX', filesize: 2048})
      const saved = render(node.exportDOM().element.outerHTML).querySelector('iframe')
      const editing = document.createElement('div')
      const decoration = node.decorate()
      let stopped = false
      decoration.props.onClick({ stopPropagation: () => { stopped = true } })
      expect(stopped).toBe(true)
      editing.innerHTML = renderToStaticMarkup(decoration)
      expect(saved.getAttribute('src')).toBe('/ppt_previews/signed')
      expect(saved.getAttribute('src')).toBe(editing.querySelector('iframe').getAttribute('src'))
      expect(saved.title).toBe('deck.PPTX')
      expect(saved.hasAttribute('allowfullscreen')).toBe(true)
      expect(saved.getAttribute('allow')).toBe('fullscreen')
      expect(saved.className).toBe(editing.querySelector('iframe').className)
      expect(sanitizeDescriptionHtml(saved.outerHTML)).toContain('/ppt_previews/signed')
      expect(node.exportDOM().element.tagName).toBe('A')
      expect(AttachmentNode.importDOM().a(node.exportDOM().element).conversion(node.exportDOM().element).node.getSrc()).toBe(src)
    }, {discrete: true})
  })

  test.each([null, '', '0', '-1', 'invalid'])('omits missing or invalid size %s', size => {
    expect(attachmentLinkParts('file', size)).toHaveLength(2)
    const editor = createEditor({nodes: [AttachmentNode], onError: error => { throw error }})
    editor.update(() => {
      const node = $createAttachmentNode({src: '/file', filename: 'file', filesize: size})
      const saved = render(node.exportDOM().element.outerHTML).querySelector('a')
      const editing = document.createElement('div')
      editing.innerHTML = renderToStaticMarkup(node.decorate())
      expect(computeAccessibleName(saved)).toBe('file')
      expect(computeAccessibleName(editing.firstChild)).toBe('file')
    }, {discrete: true})
  })

  test('formats sizes consistently and escapes filenames', () => {
    const link = render('<a href="/file" download="&lt;img onerror=alert(1)&gt;" data-filesize="1048576">file</a>').querySelector('a')
    expect(link.querySelector('.attachment-link-size').dataset.filesizeLabel).toBe('1 MB')
    expect(link.textContent).toBe('<img onerror=alert(1)>')
    expect(link.querySelector('.attachment-link-name').textContent).toBe('<img onerror=alert(1)>')
    expect(link.querySelector('img')).toBeNull()
  })

  test('uses the existing label for an empty download filename', () => {
    const once = sanitizeDescriptionHtml('<a download href="/file">report.pdf</a>')
    expect(sanitizeDescriptionHtml(once)).toBe(once)
    expect(render(once).querySelector('.attachment-link-name').textContent).toBe('report.pdf')
  })

  test('keeps labels and imported filenames free of decoration', () => {
    const link = render('<a download href="/file" data-filesize="2048">report.pdf</a>').querySelector('a')
    expect(link.textContent).toBe('report.pdf')
    const editor = createEditor({nodes: [AttachmentNode], onError: error => { throw error }})
    editor.update(() => {
      const imported = AttachmentNode.importDOM().a(link).conversion(link).node
      expect(imported.getFilename()).toBe('report.pdf')
      expect(imported.exportDOM().element.textContent).toBe('report.pdf')
    }, {discrete: true})
  })

  test('imports previously decorated HTML using the filename span', () => {
    const container = document.createElement('div')
    container.innerHTML = '<a download href="/file"><span>📎</span><span class="attachment-link-name">report.pdf</span><span>(2 KB)</span></a>'
    const link = container.firstChild
    const editor = createEditor({nodes: [AttachmentNode], onError: error => { throw error }})
    editor.update(() => {
      expect(AttachmentNode.importDOM().a(link).conversion(link).node.getFilename()).toBe('report.pdf')
    }, {discrete: true})
  })

  test('is idempotent and preserves link metadata', () => {
    const html = '<a href="/file" download="file.txt" data-filesize="42">file.txt</a>'
    const once = sanitizeDescriptionHtml(html)
    expect(sanitizeDescriptionHtml(once)).toBe(once)
    const link = render(once).querySelector('a')
    expect(link.getAttribute('href')).toBe('/file')
    expect(link.getAttribute('download')).toBe('file.txt')
    expect(link.dataset.filesize).toBe('42')
  })

  test('preserves image/video previews and ordinary links', () => {
    const html = '<img src="/image.png" width="200" alt="photo"><video controls src="/movie.mp4"></video><a download="photo.png" href="/image.png"><img src="/image.png"></a><a href="/page">page</a>'
    const output = render(html)
    expect(output.querySelectorAll('img')).toHaveLength(2)
    expect(output.querySelector('img').getAttribute('width')).toBe('200')
    expect(output.querySelector('video').hasAttribute('controls')).toBe(true)
    expect(output.querySelector('.attachment-link')).toBeNull()
    expect(output.querySelector('a:not([download])').textContent).toBe('page')
  })

  test('sanitizes unsafe links before decorating', () => {
    const link = render('<a download="file" href="javascript:alert(1)" onclick="alert(1)">file</a>').querySelector('a')
    expect(link.hasAttribute('href')).toBe(false)
    expect(link.hasAttribute('onclick')).toBe(false)
  })
})

test.each(['notes.md', 'report.HTML', 'paper.pdf', 'slides.pptx'])('shared preview renders %s in both display paths', filename => {
  document.head.innerHTML = '<meta name="ppt-preview-url-template" content="/ppt_previews/PPT_BLOB_ID"><meta name="document-loading" content="불러오는 중…">'
  const editor = createEditor({nodes: [AttachmentNode], onError: error => { throw error }})
  editor.update(() => {
    const node = $createAttachmentNode({src: '/public-assets/blobs/signed/file', filename})
    const saved = render(node.exportDOM().element.outerHTML)
    const editing = document.createElement('div')
    editing.innerHTML = renderToStaticMarkup(node.decorate())
    for (const root of [saved, editing]) {
      expect(root.querySelector('[data-controller="document-preview"]').getAttribute('aria-busy')).toBe('true')
      expect(root.querySelector('.media-loading').getAttribute('aria-label')).toBe('불러오는 중…')
      expect(root.querySelector('iframe').getAttribute('src')).toBe('/ppt_previews/signed')
    }
  }, {discrete: true})
})
