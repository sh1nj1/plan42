export function approvalRequestOptions(button) {
  const reason = button.closest('.comment-item')?.querySelector('[data-approval-reason]')?.value
  return {
    method: 'POST',
    headers: {
      'X-CSRF-Token': document.querySelector('meta[name=csrf-token]').content,
      'Content-Type': 'application/json',
      'Accept': 'text/html'
    },
    body: JSON.stringify({ reason })
  }
}
