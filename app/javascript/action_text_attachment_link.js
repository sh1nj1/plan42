

if (!window.isTrixAttachmentDownloadEnabled) {
    window.isTrixAttachmentDownloadEnabled = true;

    // To prevent infinite turbo progress bar issue, use javascript to hand attachment downloads.
    document.addEventListener('turbo:load', function () {
        const actionTextAttachments = document.getElementsByTagName('action-text-attachment');
        if (actionTextAttachments) {
            Array.from(actionTextAttachments).forEach(function (element) {
                element.addEventListener('click', function (e) {
                    e.preventDefault();

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
    });
}