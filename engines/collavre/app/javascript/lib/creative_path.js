const CREATIVE_ID_PLACEHOLDER = "__CREATIVE_ID__";

// Engine route helpers retain the host application's mount prefix. Keep the
// template server-rendered rather than deriving it from the browser location,
// whose current route can include a Creative id or comment path.
export function creativePathFromTemplate(template, creativeId) {
  const fallback = `/creatives/${CREATIVE_ID_PLACEHOLDER}`;
  return (template || fallback).replace(CREATIVE_ID_PLACEHOLDER, encodeURIComponent(creativeId));
}
