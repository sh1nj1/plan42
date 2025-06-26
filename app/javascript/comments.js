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
            subscribePresence();
            loadInitialComments();
        }
        function closePopup() {
            if (isMobile()) {
                popup.classList.remove('open');
                setTimeout(function() { popup.style.display = 'none'; }, 300);
            } else {
                popup.style.display = 'none';
            }
            document.body.classList.remove('no-scroll');
            unsubscribePresence();
        }
        var popup = document.getElementById('comments-popup');
        var closeBtn = document.getElementById('close-comments-btn');
        var list = document.getElementById('comments-list');
        var form = document.getElementById('new-comment-form');
        var participants = document.getElementById('comment-participants');
        var submitBtn = form.querySelector('button[type="submit"]');
        var textarea = form.querySelector('textarea');
        var editingId = null;
        var presenceSubscription = null;

        function subscribePresence() {
            if (!popup.dataset.creativeId) return;
            if (presenceSubscription) { presenceSubscription.unsubscribe(); }
            presenceSubscription = ActionCable.createConsumer().subscriptions.create(
                { channel: 'CommentsPresenceChannel', creative_id: popup.dataset.creativeId },
                { received: function(data) { if (data.html && participants) { participants.innerHTML = data.html; } } }
            );
        }

        function unsubscribePresence() {
            if (presenceSubscription) { presenceSubscription.unsubscribe(); presenceSubscription = null; }
        }
        if (popup) {
            function adjustForKeyboard() {
                if (!isMobile()) return;
                var inset = 0;
                if (window.visualViewport) {
                    inset = window.innerHeight - window.visualViewport.height;
                    if (inset < 0) inset = 0;
                }
                popup.style.bottom = inset + 'px';
            }
            textarea.addEventListener('focus', function() {
                adjustForKeyboard();
                if (window.visualViewport) {
                    window.visualViewport.addEventListener('resize', adjustForKeyboard);
                }
            });
            textarea.addEventListener('blur', function() {
                popup.style.bottom = '';
                if (window.visualViewport) {
                    window.visualViewport.removeEventListener('resize', adjustForKeyboard);
                }
            });
            const buttons = document.getElementsByName('show-comments-btn');
            buttons.forEach(function(btn) {
                btn.onclick = function() {
                    if (popup.style.display === 'block') { closePopup(); return; }
                    openPopup(btn);
                };
            });
            closeBtn.onclick = closePopup;
            var startY = null;
            popup.addEventListener('touchstart', function(e) {
                if (isMobile()) {
                    if (!e.target.closest('#comments-list')) {
                        startY = e.touches[0].clientY;
                    } else {
                        startY = null;
                    }
                }
            });
            popup.addEventListener('touchend', function(e) {
                if (startY !== null) {
                    var diffY = e.changedTouches[0].clientY - startY;
                    if (diffY > 50) {
                        closePopup();
                    }
                }
                startY = null;
            });

            list.addEventListener('scroll', function() {
                const pos = list.scrollHeight - list.clientHeight + list.scrollTop;
                if (pos < 50) {
                    loadMoreComments();
                }
                console.log("scrollTop:", list.scrollTop, "scrollHeight:", list.scrollHeight, "clientHeight:", list.clientHeight, "pos:", pos);
            });
            var currentPage = 1;
            var loadingMore = false;
            var allLoaded = false;

            function fetchCommentsPage(page) {
                return fetch(`/creatives/${popup.dataset.creativeId}/comments?page=${page}`)
                    .then(r => r.text());
            }

            function loadInitialComments(highlightId) {
                currentPage = 1;
                allLoaded = false;
                list.innerHTML = popup.dataset.loadingText;
                fetchCommentsPage(1).then(function(html) {
                    list.innerHTML = html;
                    updatePosition();
                    if (highlightId) {
                        var el = document.getElementById('comment_' + highlightId);
                        if (el) {
                            el.scrollIntoView({ behavior: 'smooth', block: 'center' });
                            el.classList.add('highlight-flash');
                            setTimeout(function(){ el.classList.remove('highlight-flash'); }, 2000);
                        }
                    }
                    textarea.focus();
                    if ((html.match(/class="comment-item"/g) || []).length < 10) {
                        allLoaded = true;
                    }
                });
            }

            function loadMoreComments() {
                if (loadingMore || allLoaded) return;
                console.log("Loading more comments...");
                loadingMore = true;
                fetchCommentsPage(currentPage + 1).then(function(html) {
                    if (html.trim() === '') {
                        allLoaded = true;
                    } else {
                        list.insertAdjacentHTML('beforeend', html);
                        currentPage += 1;
                        if ((html.match(/class="comment-item"/g) || []).length < 10) {
                            allLoaded = true;
                        }
                    }
                }).finally(function(){
                    loadingMore = false;
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
                        loadInitialComments(editingId);
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
                            loadInitialComments();
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
                        loadInitialComments(commentId);
                    }
                }
            }

            openFromUrl();
        }
    });
}
