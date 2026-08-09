const DEFAULT_CREATIVE_URL_TEMPLATE = '/creatives/__CREATIVE_ID__'

export function creativeUrl(element, creativeId) {
  const template = element?.dataset?.creativeUrlTemplate || DEFAULT_CREATIVE_URL_TEMPLATE
  return template.replace('__CREATIVE_ID__', encodeURIComponent(creativeId))
}

export function commentsUrl(element, creativeId) {
  return `${creativeUrl(element, creativeId)}/comments`
}
