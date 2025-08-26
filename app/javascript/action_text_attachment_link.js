

if (!window.isTrixAttachmentDownloadEnabled) {
  window.isTrixAttachmentDownloadEnabled = true;

  // To prevent infinite turbo progress bar issue, use javascript to handle attachment downloads.
  document.addEventListener('turbo:load', function () {
    document.addEventListener('click', function (e) {
      const element = e.target.closest('action-text-attachment');
      if (!element) return;

      const contentType = element.getAttribute('content-type') || '';
      if (contentType.startsWith('image/')) return;

      e.preventDefault();
      e.stopPropagation();

      const url = element.getAttribute('url');
      const filename = element.getAttribute('filename') || 'download';

      if (!url) return;

      // Create a temporary anchor element for download attachment.
      const a = document.createElement('a');
      a.href = url;
      a.download = filename;
      a.style.display = 'none';
      document.body.appendChild(a);
      a.click();
      document.body.removeChild(a);
    });
  });
}