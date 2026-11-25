export function updatePermission(select, { classes = [], onFailure }) {
  const permission = select.value
  const originalClass = select.className
  select.className = select.className.replace(/org-chart-permission-\w+/g, "")
  select.classList.add("org-chart-permission-select", ...classes, `org-chart-permission-${permission}`)

  return fetch(select.dataset.updateUrl, {
    method: "PATCH",
    headers: {
      "Content-Type": "application/json",
      "X-CSRF-Token": document.querySelector("meta[name='csrf-token']")?.content,
      "Accept": "application/json"
    },
    body: JSON.stringify({ permission })
  }).then(response => {
    if (!response.ok) throw new Error("Failed")
  }).catch(() => {
    select.className = originalClass
    onFailure()
  })
}
