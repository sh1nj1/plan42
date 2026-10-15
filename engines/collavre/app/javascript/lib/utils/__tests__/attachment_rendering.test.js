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
  test('renders the same attachment contents and class as the editor', () => {
    const editor = createEditor({nodes: [AttachmentNode]})
    editor.update(() => {
      const node = $createAttachmentNode({src: '/file', filename: 'slides.pptx', filesize: 2048})
      const saved = render(node.exportDOM().element.outerHTML).querySelector('a')
      const editing = document.createElement('div')
      editing.innerHTML = renderToStaticMarkup(node.decorate())
      expect(saved.innerHTML).toBe(editing.firstChild.innerHTML)
      expect(saved.className).toBe(editing.firstChild.className)
      expect(saved.getAttribute('href')).toBe(editing.firstChild.getAttribute('href'))
      expect(saved.getAttribute('download')).toBe(editing.firstChild.getAttribute('download'))
    }, {discrete: true})
  })

  test.each([null, '', '0', '-1', 'invalid'])('omits missing or invalid size %s', size => {
    expect(attachmentLinkParts('file', size)).toHaveLength(2)
  })

  test('formats sizes consistently and escapes filenames', () => {
    const link = render('<a href="/file" download="&lt;img onerror=alert(1)&gt;" data-filesize="1048576">file</a>').querySelector('a')
    expect(link.querySelector('.attachment-link-size').textContent).toBe('(1 MB)')
    expect(link.querySelector('.attachment-link-name').textContent).toBe('<img onerror=alert(1)>')
    expect(link.querySelector('img')).toBeNull()
  })

  test('uses the existing label for an empty download filename', () => {
    expect(render('<a download href="/file">report.pdf</a>').querySelector('.attachment-link-name').textContent).toBe('report.pdf')
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
