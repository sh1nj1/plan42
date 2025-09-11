if (!window.commentsInitialized) {
    window.commentsInitialized = true;

    document.addEventListener('turbo:load', function() {
        function isMobile() { return window.innerWidth <= 600; }
        var sizeKey = 'commentsPopupSize';
        document.querySelectorAll('form[action="/session"]').forEach(function(form) {
            form.addEventListener('submit', function() {
                localStorage.removeItem(sizeKey);
            });
        });
        var currentBtn = null;
        function updatePosition() {
            if (!currentBtn || isMobile() || popup.dataset.resized === 'true') return;
            var rect = currentBtn.getBoundingClientRect();
            var scrollY = window.scrollY || window.pageYOffset;
            var top = rect.bottom + scrollY + 4;
            var bottom = top + popup.offsetHeight;
            var viewportBottom = scrollY + window.innerHeight;
            if (bottom > viewportBottom) {
                top = Math.max(scrollY + 4, viewportBottom - popup.offsetHeight - 4);
            }
            popup.style.top = top + 'px';
            popup.style.right = (window.innerWidth - rect.right + 24) + 'px';
            popup.style.left = '';
        }
        function openPopup(btn) {
            currentBtn = btn;
            resetForm();
            popup.dataset.creativeId = btn.dataset.creativeId;
            popup.dataset.canComment = btn.dataset.canComment;
            popup.dataset.resized = 'false';
            document.getElementById('comments-popup-title').textContent = btn.dataset.creativeSnippet;
            popup.style.width = '';
            popup.style.height = '';
            popup.style.left = '';
            popup.style.right = '';
            list.style.height = '';
            reservedHeight = popup.offsetHeight - list.offsetHeight;
            var storedSize = localStorage.getItem(sizeKey);
            if (storedSize) {
                try {
                    var sz = JSON.parse(storedSize);
                    if (sz.width) { popup.style.width = sz.width; }
                    if (sz.height) {
                        popup.style.height = sz.height;
                        list.style.height = (parseInt(sz.height, 10) - reservedHeight) + 'px';
                    }
                } catch (e) {}
            }
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
            participantsData = null;
            currentPresentIds = [];
            typingUsers = {};
            renderTypingIndicator();
            loadParticipants();
            subscribePresence();
            loadInitialComments();
        }
        function closePopup() {
            if (presenceSubscription && (!privateCheckbox || !privateCheckbox.checked)) { presenceSubscription.perform('stopped_typing'); }
            clearTimeout(typingTimeout);
            typingTimeout = null;
            resetForm();
            if (isMobile()) {
                popup.classList.remove('open');
                setTimeout(function() { popup.style.display = 'none'; }, 300);
            } else {
                popup.style.display = 'none';
            }
            document.body.classList.remove('no-scroll');
            markCommentsRead();
            unsubscribePresence();
        }
        var popup = document.getElementById('comments-popup');
        var closeBtn = document.getElementById('close-comments-btn');
        var list = document.getElementById('comments-list');
        var form = document.getElementById('new-comment-form');
        var participants = document.getElementById('comment-participants');
        var typingIndicator = document.getElementById('typing-indicator');
        var submitBtn = form.querySelector('button[type="submit"]');
        var defaultSubmitBtnHTML = submitBtn.innerHTML;
        var textarea = form.querySelector('textarea');
        var privateCheckbox = form.querySelector('#comment-private');
        var cancelBtn = form.querySelector('#cancel-edit-btn');
        var leftHandle = popup.querySelector('.resize-handle-left');
        var rightHandle = popup.querySelector('.resize-handle-right');
        var editingId = null;
        var presenceSubscription = null;
        var participantsData = null;
        var currentPresentIds = [];
        var typingUsers = {};
        var typingTimers = {};
        var typingTimeout = null;
        var hasPresenceConnected = false;

        if (privateCheckbox) {
            privateCheckbox.addEventListener('change', function() {
                if (presenceSubscription && privateCheckbox.checked) {
                    presenceSubscription.perform('stopped_typing');
                }
                clearTimeout(typingTimeout);
                typingTimeout = null;
            });
        }

        if (cancelBtn) {
            cancelBtn.addEventListener('click', function() {
                resetForm();
            });
        }

        var resizing = null;
        var resizeStartX = 0;
        var resizeStartY = 0;
        var startWidth = 0;
        var startHeight = 0;
        var startLeft = 0;
        var startTop = 0;
        var startBottom = 0;
        var reservedHeight = 0;

        function renderMarkdown(container) {
            if (!window.marked) return;
            container.querySelectorAll('.comment-content').forEach(function(el) {
                if (el.dataset.rendered === 'true') return;
                el.innerHTML = window.marked.parse(el.textContent);
                el.dataset.rendered = 'true';
            });
        }

        document.addEventListener('turbo:after-stream-render', function() {
            renderMarkdown(document);
        });

        function startResize(e, dir) {
            e.preventDefault();
            var rect = popup.getBoundingClientRect();
            resizeStartX = e.clientX;
            resizeStartY = e.clientY;
            startWidth = rect.width;
            startHeight = rect.height;
            startLeft = rect.left + window.scrollX;
            startTop = rect.top + window.scrollY;
            startBottom = startTop + startHeight;
            reservedHeight = popup.offsetHeight - list.offsetHeight;
            popup.style.left = startLeft + 'px';
            popup.style.right = '';
            resizing = dir;
            popup.dataset.resized = 'true';
            window.addEventListener('mousemove', doResize);
            window.addEventListener('mouseup', stopResize);
        }

        function doResize(e) {
            if (!resizing) return;
            var dx = e.clientX - resizeStartX;
            var dy = e.clientY - resizeStartY;
            var newWidth = startWidth;
            var newLeft = startLeft;
            if (resizing === 'left') {
                newWidth = Math.max(200, startWidth - dx);
                newLeft = startLeft + dx;
                if (newWidth === 200) { newLeft = startLeft + (startWidth - 200); }
                popup.style.left = newLeft + 'px';
            } else if (resizing === 'right') {
                newWidth = Math.max(200, startWidth + dx);
            }
            popup.style.width = newWidth + 'px';

            var newTop = startTop + dy;
            var newHeight = startBottom - newTop;
            if (newHeight < 200) {
                newHeight = 200;
                newTop = startBottom - 200;
            }
            popup.style.top = newTop + 'px';
            popup.style.height = newHeight + 'px';
            list.style.height = (newHeight - reservedHeight) + 'px';
        }

        function stopResize() {
            if (resizing) {
                localStorage.setItem(sizeKey, JSON.stringify({
                    width: popup.style.width,
                    height: popup.style.height
                }));
            }
            resizing = null;
            window.removeEventListener('mousemove', doResize);
            window.removeEventListener('mouseup', stopResize);
        }

        if (leftHandle) { leftHandle.addEventListener('mousedown', function(e){ startResize(e, 'left'); }); }
        if (rightHandle) { rightHandle.addEventListener('mousedown', function(e){ startResize(e, 'right'); }); }

        function insertMention(user) {
            var start = textarea.selectionStart;
            var end = textarea.selectionEnd;
            var mentionText = '@' + user.name + ': ';

            if (start !== end) {
                // 선택영역이 있는 경우: 선택영역을 멘션으로 바꿈
                var before = textarea.value.slice(0, start);
                var after = textarea.value.slice(end);
                textarea.value = before + mentionText + after;
                textarea.setSelectionRange(start + mentionText.length, start + mentionText.length);
            } else {
                // 선택영역이 없는 경우: 멘션을 현재 커서에 삽입
                var before = textarea.value.slice(0, start);
                var after = textarea.value.slice(start);
                textarea.value = before + mentionText + after;
                textarea.setSelectionRange(start + mentionText.length, start + mentionText.length);
            }
        }

        // TODO: better use some templating framework like Lit or... something else.
        function renderParticipants(presentIds) {
            if (!participants || !participantsData) return;
            participants.innerHTML = '';
            participantsData.forEach(function(u) {
                var wrapper = document.createElement('div');
                wrapper.className = 'avatar-wrapper';
                wrapper.style.width = '20px';
                wrapper.style.height = '20px';

                var img = document.createElement('img');
                img.src = u.avatar_url;
                img.alt = '';
                img.width = 20;
                img.height = 20;
                var classes = 'avatar comment-presence-avatar';
                if (presentIds.indexOf(u.id) === -1) {
                    classes += ' inactive';
                }
                img.className = classes;
                img.title = u.name;
                img.style.borderRadius = '50%';
                img.style.verticalAlign = 'middle';
                if (u.email) { img.dataset.email = u.email; }
                img.dataset.userId = u.id;
                img.dataset.userName = u.name;
                wrapper.appendChild(img);

                if (u.default_avatar) {
                    var span = document.createElement('span');
                    span.className = 'avatar-initial';
                    span.textContent = u.initial;
                    span.style.fontSize = Math.round(20 / 2) + 'px';
                    wrapper.appendChild(span);
                }

                participants.appendChild(wrapper);
            });
        }

        function renderTypingIndicator() {
            if (!typingIndicator) return;
            typingIndicator.innerHTML = '';
            var ids = Object.keys(typingUsers);
            if (ids.length === 0) {
                typingIndicator.style.visibility = 'hidden';
                return;
            }
            typingIndicator.style.visibility = 'visible';
            if (participantsData) {
                ids.forEach(function(id) {
                    var user = participantsData.find(function(u) { return u.id === parseInt(id, 10); });
                    if (!user) return;
                    var wrapper = document.createElement('span');
                    wrapper.className = 'avatar-wrapper';
                    var img = document.createElement('img');
                    img.src = user.avatar_url;
                    img.alt = '';
                    img.width = 20;
                    img.height = 20;
                    img.className = 'avatar comment-presence-avatar';
                    img.style.borderRadius = '50%';
                    wrapper.appendChild(img);
                    if (user.default_avatar) {
                        var span = document.createElement('span');
                        span.className = 'avatar-initial';
                        span.textContent = user.initial;
                        span.style.fontSize = Math.round(20 / 2) + 'px';
                        wrapper.appendChild(span);
                    }
                    typingIndicator.appendChild(wrapper);
                });
            }
            var names = ids.map(function(id) { return typingUsers[id]; });
            var text = document.createElement('span');
            text.textContent = names.join(', ') + ' ...';
            typingIndicator.appendChild(text);
        }

        function loadParticipants() {
            if (!popup.dataset.creativeId) return;
            fetch(`/creatives/${popup.dataset.creativeId}/comments/participants`)
                .then(function(r) { return r.json(); })
                .then(function(data) {
                    participantsData = data;
                    renderParticipants(currentPresentIds);
                    renderTypingIndicator();
                });
        }

        function subscribePresence() {
            if (!popup.dataset.creativeId) return;
            if (presenceSubscription) { presenceSubscription.unsubscribe(); }
            hasPresenceConnected = false;
            presenceSubscription = ActionCable.createConsumer().subscriptions.create(
                { channel: 'CommentsPresenceChannel', creative_id: popup.dataset.creativeId },
                {
                    connected: function() {
                        if (hasPresenceConnected) {
                            loadInitialComments();
                        }
                        hasPresenceConnected = true;
                    },
                    received: function(data) {
                        if (data.ids) {
                            currentPresentIds = data.ids.map(function(id) { return parseInt(id, 10); });
                            renderParticipants(currentPresentIds);
                        }
                        if (data.typing) {
                        var id = data.typing.id;
                        typingUsers[id] = data.typing.name;
                        renderTypingIndicator();
                        clearTimeout(typingTimers[id]);
                        typingTimers[id] = setTimeout(function() {
                            delete typingUsers[id];
                            renderTypingIndicator();
                            delete typingTimers[id];
                        }, 3000);
                    }
                    if (data.stop_typing) {
                        var id2 = data.stop_typing.id;
                        delete typingUsers[id2];
                        if (typingTimers[id2]) { clearTimeout(typingTimers[id2]); delete typingTimers[id2]; }
                        renderTypingIndicator();
                    }
                } }
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
                    var vv = window.visualViewport;
                    inset = window.innerHeight - (vv.height + vv.offsetTop);
                    if (inset < 0) inset = 0;
                }
                popup.style.bottom = inset + 'px';
            }
            textarea.addEventListener('input', function() {
                if (!presenceSubscription) return;
                if (privateCheckbox && privateCheckbox.checked) {
                    presenceSubscription.perform('stopped_typing');
                    clearTimeout(typingTimeout);
                    typingTimeout = null;
                    return;
                }
                presenceSubscription.perform('typing');
                clearTimeout(typingTimeout);
                typingTimeout = setTimeout(function() {
                    if (presenceSubscription) { presenceSubscription.perform('stopped_typing'); }
                }, 3000);
            });
            textarea.addEventListener('keydown', function(e) {
                if (e.key === 'Enter' && e.shiftKey) {
                    e.preventDefault();
                    if (form.requestSubmit) {
                        form.requestSubmit(submitBtn);
                    } else {
                        submitBtn.click();
                    }
                }
            });
            textarea.addEventListener('focus', function() {
                adjustForKeyboard();
                if (window.visualViewport) {
                    window.visualViewport.addEventListener('resize', adjustForKeyboard);
                }
            });
            textarea.addEventListener('blur', function() {
                if (presenceSubscription && (!privateCheckbox || !privateCheckbox.checked)) { presenceSubscription.perform('stopped_typing'); }
                clearTimeout(typingTimeout);
                typingTimeout = null;
                popup.style.bottom = '';
                if (window.visualViewport) {
                    window.visualViewport.removeEventListener('resize', adjustForKeyboard);
                }
            });
            function attachCommentButtons() {
                const buttons = document.getElementsByName('show-comments-btn');
                buttons.forEach(function(btn) {
                    btn.onclick = function() {
                        if (popup.style.display === 'block' && popup.dataset.creativeId === btn.dataset.creativeId) {
                            closePopup();
                            return;
                        }
                        openPopup(btn);
                    };
                });
            }
            attachCommentButtons();
            window.attachCommentButtons = attachCommentButtons;
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

            participants.addEventListener('click', function(e) {
                var avatar = e.target.closest('.comment-presence-avatar');
                if (avatar && avatar.dataset.userId && avatar.dataset.userName) {
                    insertMention({ id: avatar.dataset.userId, name: avatar.dataset.userName });
                    textarea.focus();
                }
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

            function markCommentsRead() {
                fetch('/comment_read_pointers/update', {
                    method: 'POST',
                    headers: {
                        'X-CSRF-Token': document.querySelector('meta[name=csrf-token]').content,
                        'Content-Type': 'application/json'
                    },
                    body: JSON.stringify({ creative_id: popup.dataset.creativeId })
                });
            }

            function checkAllLoaded(html) {
                if ((html.match(/class="comment-item /g) || []).length < 10) {
                    allLoaded = true;
                }
            }

            function loadInitialComments(highlightId) {
                currentPage = 1;
                allLoaded = false;
                list.innerHTML = popup.dataset.loadingText;
                fetchCommentsPage(1).then(function(html) {
                    list.innerHTML = html;
                    renderMarkdown(list);
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
                    checkAllLoaded(html);
                    markCommentsRead();
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
                        renderMarkdown(list);
                        currentPage += 1;
                        checkAllLoaded(html);
                    }
                }).finally(function(){
                    loadingMore = false;
                });
            }

            function resetForm() {
                form.reset();
                editingId = null;
                submitBtn.innerHTML = defaultSubmitBtnHTML;
                if (cancelBtn) { cancelBtn.style.display = 'none'; }
            }

            const send = function(e) {
                e.preventDefault();
                if (!textarea.value) return;
                if (presenceSubscription && (!privateCheckbox || !privateCheckbox.checked)) { presenceSubscription.perform('stopped_typing'); }
                clearTimeout(typingTimeout);
                typingTimeout = null;
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
            }

            submitBtn.addEventListener('click', send);
            // iOS에서 키보드 열림 중 click 유실 대비
            submitBtn.addEventListener('pointerup', (e)=>{ if (e.pointerType !== 'mouse') send(e); });
            submitBtn.addEventListener('touchend', (e)=>{ e.preventDefault(); send(e); }, {passive:false});

            if (isMobile()) { // mobile 에선 쉽프트 엔터킬로 보내는 건 무의미
                // 키보드의 엔터(‘보내기’ 표시)로도 보낼 수 있게
                textarea.addEventListener('keydown', (e)=>{
                    if (e.key === 'Enter' && !e.shiftKey) { e.preventDefault(); send(e); }
                });
            }
            form.onsubmit = send;
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
               } else if (e.target.classList.contains('convert-comment-btn')) {
                   e.preventDefault();
                    if (!confirm(popup.dataset.convertConfirmText)) return;
                   var btn = e.target;
                   var commentId = btn.getAttribute('data-comment-id');
                   var creativeId = popup.dataset.creativeId;
                   fetch(`/creatives/${creativeId}/comments/${commentId}/convert`, {
                       method: 'POST',
                       headers: { 'X-CSRF-Token': document.querySelector('meta[name=csrf-token]').content }
                    }).then(function(r) {
                        if (r.ok) {
                            loadInitialComments();
                        }
                    });
                } else if (e.target.classList.contains('edit-comment-btn')) {
                    e.preventDefault();
                    var btn = e.target;
                    editingId = btn.getAttribute('data-comment-id');
                    textarea.value = btn.getAttribute('data-comment-content');
                    submitBtn.textContent = popup.dataset.updateCommentText;
                    if (privateCheckbox) {
                        privateCheckbox.checked = btn.getAttribute('data-comment-private') === 'true';
                        privateCheckbox.dispatchEvent(new Event('change'));
                    }
                    if (cancelBtn) { cancelBtn.style.display = ''; }
                    textarea.focus();
                }
            });

            function openFromUrl() {
                var params = new URLSearchParams(window.location.search);
                var commentId = params.get('comment_id');
                var match = window.location.pathname.match(/\/creatives\/(\d+)/);
                var creativeId;
                if (match) {
                    creativeId = match[1];
                } else {
                    creativeId = params.get('id')
                }
                if (commentId && creativeId) {
                    var btn = document.querySelector('[name="show-comments-btn"][data-creative-id="' + creativeId + '"]');
                    if (btn) {
                        openPopup(btn);
                        loadInitialComments(commentId);
                    }
                }
            }

            openFromUrl();

            window.addEventListener('online', function() {
                if (popup.style.display === 'block') {
                    loadInitialComments();
                }
            });

            window.addEventListener('focus', function() {
                if (popup.style.display === 'block') {
                    loadInitialComments();
                }
            });

            document.addEventListener('visibilitychange', function() {
                if (!document.hidden && popup.style.display === 'block') {
                    loadInitialComments();
                }
            });
        }
    });
}
