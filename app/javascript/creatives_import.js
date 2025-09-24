// creatives_import.js
// Handles the import button, slide, drag & drop, and AJAX upload for markdown and PPT files
if (!window.creativesImportInitialized) {
    window.creativesImportInitialized = true;
    document.addEventListener('turbo:load', function () {
        const importBtn = document.getElementById('import-markdown-btn');
        const importArea = document.getElementById('import-markdown-area');
        const fileInput = document.getElementById('import-markdown-input');
        const dropZone = document.getElementById('import-markdown-dropzone');
        const progress = document.getElementById('import-markdown-progress');
        if (!importBtn || !importArea) return;

        const uploadingText = dropZone.dataset.uploading;
        const successText = dropZone.dataset.success;
        const failedText = dropZone.dataset.failed;
        const onlyMarkdownText = dropZone.dataset.onlyMarkdown;

        function showProgress(message) {
            if (progress) {
                progress.style.display = 'block';
                progress.textContent = message;
            }
        }

        function hideProgress() {
            if (progress) {
                progress.style.display = 'none';
                progress.textContent = '';
            }
        }

        importBtn.addEventListener('click', function () {
            importArea.style.display = importArea.style.display === 'block' ? 'none' : 'block';
            hideProgress();
        });

        // Drag & drop
        dropZone.addEventListener('dragover', function (e) {
            e.preventDefault();
            dropZone.classList.add('dragover');
        });
        dropZone.addEventListener('dragleave', function () {
            dropZone.classList.remove('dragover');
        });
        dropZone.addEventListener('drop', function (e) {
            e.preventDefault();
            dropZone.classList.remove('dragover');
            const file = e.dataTransfer.files[0];
            handleFile(file);
        });
        dropZone.addEventListener('click', function () {
            fileInput.click();
        });
        fileInput.addEventListener('change', function (e) {
            if (e.target.files.length > 0) {
                handleFile(e.target.files[0]);
            }
        });

        function handleFile(file) {
            const lower = file.name.toLowerCase();
            const isMarkdown = lower.endsWith('.md');
            const isPpt = lower.endsWith('.ppt') || lower.endsWith('.pptx');
            if (!isMarkdown && !isPpt) {
                alert(onlyMarkdownText);
                return;
            }
            showProgress(uploadingText);
            const formData = new FormData();
            formData.append('markdown', file);
            const parentId = importArea.dataset.parentCreativeId;
            if (parentId) formData.append('parent_id', parentId);

            fetch('/creative_imports', {
                method: 'POST',
                headers: {
                    'X-CSRF-Token': document.querySelector('meta[name="csrf-token"]')?.content
                },
                body: formData
            })
                .then(response => response.json())
                .then(data => {
                    if (data.success) {
                        showProgress(successText);
                        setTimeout(() => {
                            window.location.reload();
                        }, 700);
                    } else {
                        showProgress(data.error || failedText);
                        setTimeout(hideProgress, 3000);
                    }
                })
                .catch(() => {
                    showProgress(failedText);
                    setTimeout(hideProgress, 3000);
                });
        }
    });
}
