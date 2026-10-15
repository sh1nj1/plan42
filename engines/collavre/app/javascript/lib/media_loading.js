export function mediaLoadingProps() {
  return {className: 'media-loading', role: 'status',
    'aria-label': document.querySelector('meta[name="document-loading"]')?.content || ''}
}

export function createMediaLoading() {
  const loading = document.createElement('span')
  for (const [key, value] of Object.entries(mediaLoadingProps())) {
    loading.setAttribute(key === 'className' ? 'class' : key, value)
  }
  return loading
}

export function loadImageWithPlaceholder(image, {fullSrc, alt}) {
  image.parentElement.querySelector('.media-loading')?.remove()
  const loading = createMediaLoading()
  image.parentElement.appendChild(loading)
  image.style.opacity = '0'
  const loaded = () => { image.style.opacity = '1'; loading.remove() }
  image.onload = loaded
  image.onerror = () => loading.remove()
  image.src = fullSrc
  image.alt = alt || ''
  if (image.complete) loaded()
}
