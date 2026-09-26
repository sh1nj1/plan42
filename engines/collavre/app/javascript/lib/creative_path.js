import csrfFetch from "./api/csrf_fetch";

const CREATIVE_ID_PLACEHOLDER = "__CREATIVE_ID__";

// Engine route helpers retain the host application's mount prefix. Keep the
// template server-rendered rather than deriving it from the browser location,
// whose current route can include a Creative id or comment path.
export function creativePathFromTemplate(template, creativeId) {
  const fallback = `/creatives/${CREATIVE_ID_PLACEHOLDER}`;
  return (template || fallback).replace(CREATIVE_ID_PLACEHOLDER, encodeURIComponent(creativeId));
}

export function updateCreativeProgress(element, creativeId, progress) {
  const template = element.closest("[data-creative-path-template]")?.dataset.creativePathTemplate;
  const body = new FormData();
  body.append("creative[progress]", progress);
  return csrfFetch(creativePathFromTemplate(template, creativeId), {
    method: "PATCH", headers: { Accept: "application/json" }, body,
  });
}

export function commentRequest(element, creativeId, editingId) {
  const base = `${creativePathFromTemplate(element.dataset.creativePathTemplate, creativeId)}/comments`;
  return editingId ? { url: `${base}/${editingId}`, method: "PATCH" } : { url: base, method: "POST" };
}
