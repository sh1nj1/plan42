if (!window.commentsInitialized) {
    window.commentsInitialized = true;

    document.addEventListener('turbo:load', function() {
        function isMobile() { return window.innerWidth <= 600; }
        var currentBtn = null;
        function updatePosition() {
            if (!currentBtn || isMobile()) return;
            var rect = currentBtn.getBoundingClientRect();
            var scrollY = window.scrollY || window.pageYOffset;
            var top = rect.bottom + scrollY + 4;
            var bottom = top + popup.offsetHeight;
            var viewportBottom = scrollY + window.innerHeight;
            if (bottom > viewportBottom) {
                top = Math.max(scrollY + 4, viewportBottom - popup.offsetHeight - 4);
            }
            popup.style.top = top + 'px';
            popup.style.right = (window.innerWidth - rect.right) + 'px';
            popup.style.left = '';
        }
        function openPopup(btn) {
            currentBtn = btn;
            popup.dataset.creativeId = btn.dataset.creativeId;
            popup.dataset.canComment = btn.dataset.canComment;
            form.style.display = (popup.dataset.canComment === 'true') ? '' : 'none';
            if (isMobile()) {
                popup.style.display = 'block';
                popup.classList.add('open');
                document.body.classList.add('no-scroll');
            } else {
                popup.style.display = 'block';
                document.body.classList.add('no-scroll');
                updatePosition();
            }
            fetchComments();
        }
        function closePopup() {
            if (isMobile()) {
                popup.classList.remove('open');
                setTimeout(function() { popup.style.display = 'none'; }, 300);
            } else {
                popup.style.display = 'none';
            }
            document.body.classList.remove('no-scroll');
        }
        var popup = document.getElementById('comments-popup');
        var closeBtn = document.getElementById('close-comments-btn');
        var list = document.getElementById('comments-list');
        var form = document.getElementById('new-comment-form');
        var submitBtn = form.querySelector('button[type="submit"]');
        var textarea = form.querySelector('textarea');
        var editingId = null;
        if (popup) {
            const buttons = document.getElementsByName('show-comments-btn');
            buttons.forEach(function(btn) {
                btn.onclick = function() {
                    if (popup.style.display === 'block') { closePopup(); return; }
                    openPopup(btn);
                };
            });
            closeBtn.onclick = closePopup;
            function fetchComments(highlightId) {
                list.innerHTML = popup.dataset.loadingText;
                fetch(`/creatives/${popup.dataset.creativeId}/comments`)
                    .then(r => r.text()).then(html => {
                        list.innerHTML = html;
                        updatePosition();
                        if (highlightId) {
                            var el = document.getElementById('comment_' + highlightId);
                            if (el) {
                                el.classList.add('highlight-flash');
                                setTimeout(function(){ el.classList.remove('highlight-flash'); }, 2000);
                            }
                        }
                    });
            }
            function resetForm() {
                form.reset();
                editingId = null;
                submitBtn.textContent = popup.dataset.addCommentText;
            }

            form.onsubmit = function(e) {
                e.preventDefault();
                var formData = new FormData(form);
                var url = `/creatives/${popup.dataset.creativeId}/comments`;
                var method = 'POST';
                if (editingId) {
                    url += `/${editingId}`;
                    method = 'PATCH';
                }
                fetch(url, {
                    method: method,
                    headers: { 'X-CSRF-Token': document.querySelector('meta[name=csrf-token]').content },
                    body: formData
                })
                    .then(r => r.ok ? r.text() : r.json().then(j => { throw new Error(j.errors.join(', ')); }))
                    .then(html => {
                        resetForm();
                        fetchComments(editingId);
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
                } else if (e.target.classList.contains('edit-comment-btn')) {
                    e.preventDefault();
                    var btn = e.target;
                    editingId = btn.getAttribute('data-comment-id');
                    textarea.value = btn.getAttribute('data-comment-content');
                    submitBtn.textContent = popup.dataset.updateCommentText;
                    textarea.focus();
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
                        openPopup(btn);
                        fetchComments(commentId);
                    }
                }
            }

            openFromUrl();
        }
    });
}
