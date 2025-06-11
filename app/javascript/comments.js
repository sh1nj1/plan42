if (!window.commentsInitialized) {
    window.commentsInitialized = true;

    document.addEventListener('turbo:load', function() {
        var popup = document.getElementById('comments-popup');
        var closeBtn = document.getElementById('close-comments-btn');
        var list = document.getElementById('comments-list');
        var form = document.getElementById('new-comment-form');
        if (popup) {
            const buttons = document.getElementsByName('show-comments-btn');
            buttons.forEach(function(btn) {
                btn.onclick = function() {
                    // Toggle: if popup is open, close it; otherwise, open and position
                    if (popup.style.display === 'block') {
                        popup.style.display = 'none';
                        return;
                    }
                    popup.dataset.creativeId = btn.dataset.creativeId;
                    // 버튼 위치 계산
                    var rect = btn.getBoundingClientRect();
                    var scrollY = window.scrollY || window.pageYOffset;
                    popup.style.top = (rect.bottom + scrollY + 4) + 'px'; // 버튼 바로 아래에 4px 여유
                    popup.style.right = (window.innerWidth - rect.right) + 'px';
                    popup.style.left = '';
                    popup.style.display = 'block';
                    fetchComments();
                };
            });
            closeBtn.onclick = function() { popup.style.display = 'none'; };
            function fetchComments(highlightId) {
                list.innerHTML = popup.dataset.loadingText;
                fetch(`/creatives/${popup.dataset.creativeId}/comments`)
                    .then(r => r.text()).then(html => {
                        list.innerHTML = html;
                        if (highlightId) {
                            var el = document.getElementById('comment-' + highlightId);
                            if (el) {
                                el.classList.add('highlight-flash');
                                setTimeout(function(){ el.classList.remove('highlight-flash'); }, 2000);
                            }
                        }
                    });
            }
            form.onsubmit = function(e) {
                e.preventDefault();
                var formData = new FormData(form);
                fetch(`/creatives/${popup.dataset.creativeId}/comments`, {
                    method: 'POST',
                    headers: { 'X-CSRF-Token': document.querySelector('meta[name=csrf-token]').content },
                    body: formData
                })
                    .then(r => r.ok ? r.text() : r.json().then(j => { throw new Error(j.errors.join(', ')); }))
                    .then(html => {
                        form.reset();
                        fetchComments();
                    })
                    .catch(e => { alert(e.message); });
            };
            // 이벤트 위임 방식으로 삭제 버튼 처리
            list.addEventListener('click', function(e) {
                if (e.target.classList.contains('delete-comment-btn')) {
                    e.preventDefault();
                    if (!confirm(popup.dataset.deleteConfirmText)) return;
                    var btn = e.target;
                    var commentId = btn.getAttribute('data-comment-id');
                    var creativeId = popup.dataset.creativeId;
                    fetch(`/creatives/${creativeId}/comments/${commentId}`, {
                        method: 'DELETE',
                        headers: { 'X-CSRF-Token': document.querySelector('meta[name=csrf-token]').content }
                    }).then(function(r) {
                        if (r.ok) {
                            fetchComments();
                        } else {
                            // TODO: handle error
                        }
                    });
                }
            });

            function openFromUrl() {
                var params = new URLSearchParams(window.location.search);
                var commentId = params.get('comment_id');
                var match = window.location.pathname.match(/\/creatives\/(\d+)/);
                if (commentId && match) {
                    var creativeId = match[1];
                    var btn = document.querySelector('[name="show-comments-btn"][data-creative-id="' + creativeId + '"]');
                    if (btn) {
                        var rect = btn.getBoundingClientRect();
                        var scrollY = window.scrollY || window.pageYOffset;
                        popup.dataset.creativeId = creativeId;
                        popup.style.top = (rect.bottom + scrollY + 4) + 'px';
                        popup.style.right = (window.innerWidth - rect.right) + 'px';
                        popup.style.left = '';
                        popup.style.display = 'block';
                        fetchComments(commentId);
                    }
                }
            }

            openFromUrl();
        }
    });
}