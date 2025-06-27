
if (!window.isExportMarkdownEnabled) {
    window.isExportMarkdownEnabled = true;

    document.addEventListener('turbo:load', function () {
        const exportBtn = document.getElementById('export-markdown-btn');
        if (exportBtn) {
            exportBtn.addEventListener('click', function () {
                // 서버에서 마크다운을 받아 파일로 저장
                fetch('/creatives/export_markdown' + (exportBtn.dataset.parentCreativeId ? ('?parent_id=' + exportBtn.dataset.parentCreativeId) : ''), {
                    headers: {'Accept': 'text/markdown'}
                })
                    .then(resp => resp.ok ? resp.text() : Promise.reject(exportBtn.dataset.error))
                    .then(md => {
                        const blob = new Blob([md], {type: 'text/markdown'});
                        const url = URL.createObjectURL(blob);
                        const a = document.createElement('a');
                        a.href = url;
                        a.download = 'creatives.md';
                        document.body.appendChild(a);
                        a.click();
                        setTimeout(() => {
                            document.body.removeChild(a);
                            URL.revokeObjectURL(url);
                        }, 0);
                    })
                    .catch(err => alert(err));
            });
        }
    });
}
