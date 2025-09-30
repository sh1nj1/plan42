import { copyTextToClipboard } from './utils/clipboard';

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
        let resetForm;
        let loadInitialComments;
        let markCommentsRead;
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
        var list = document.getElementById('comments-list');
        var form = document.getElementById('new-comment-form');

        if (!popup || !list || !form) { return; }

        function showCopyFeedback(commentElement, message) {
            if (!commentElement || !message) return;
            var existing = commentElement.querySelector('.comment-copy-notice');
            if (existing) {
                existing.remove();
            }
            var notice = document.createElement('div');
            notice.className = 'comment-copy-notice';
            notice.textContent = message;
            commentElement.appendChild(notice);
            requestAnimationFrame(function() {
                notice.classList.add('visible');
            });
            setTimeout(function() {
                notice.classList.remove('visible');
            }, 2000);
            setTimeout(function() {
                notice.remove();
            }, 2400);
        }

        function getActionContainer(element) {
            if (!element) return null;
            return element.closest('.comment-action-block');
        }

        function openActionEditor(container) {
            if (!container) return;
            var jsonDisplay = container.querySelector('.comment-action-json');
            var form = container.querySelector('.comment-action-edit-form');
            var editBtn = container.querySelector('.edit-comment-action-btn');
            if (!jsonDisplay || !form) return;
            var textareaField = form.querySelector('.comment-action-edit-textarea');
            if (!textareaField) return;
            textareaField.value = jsonDisplay.textContent || '';
            form.style.display = 'block';
            if (editBtn) { editBtn.style.display = 'none'; }
            jsonDisplay.style.display = 'none';
            textareaField.focus();
            if (textareaField.setSelectionRange) {
                var length = textareaField.value.length;
                textareaField.setSelectionRange(length, length);
            }
        }

        function closeActionEditor(container) {
            if (!container) return;
            var jsonDisplay = container.querySelector('.comment-action-json');
            var form = container.querySelector('.comment-action-edit-form');
            var editBtn = container.querySelector('.edit-comment-action-btn');
            if (form) { form.style.display = 'none'; }
            if (jsonDisplay) { jsonDisplay.style.display = ''; }
            if (editBtn) { editBtn.style.display = ''; }
        }

        var closeBtn = document.getElementById('close-comments-btn');
        var participants = document.getElementById('comment-participants');
        var typingIndicator = document.getElementById('typing-indicator');
        var submitBtn = form.querySelector('button[type="submit"]');
        var defaultSubmitBtnHTML = submitBtn.innerHTML;
        var textarea = form.querySelector('textarea');
        var privateCheckbox = form.querySelector('#comment-private');
        var cancelBtn = form.querySelector('#cancel-edit-btn');
        var searchBtn = form.querySelector('#search-comments-btn');
        var leftHandle = popup.querySelector('.resize-handle-left');
        var rightHandle = popup.querySelector('.resize-handle-right');
        var editingId = null;
        var presenceSubscription = null;
        var participantsData = null;
        var currentPresentIds = [];
        var typingUsers = {};
        var typingTimers = {};
        var typingTimeout = null;
        var manualTypingMessage = null;
        
        function setManualTypingMessage(message) {
            manualTypingMessage = message && message.length > 0 ? message : null;
            renderTypingIndicator();
        }

        function clearManualTypingMessage() {
            if (manualTypingMessage !== null) {
                manualTypingMessage = null;
                renderTypingIndicator();
            }
        }
        var hasPresenceConnected = false;

        var computedStyle = window.getComputedStyle ? window.getComputedStyle(list) : null;
        var isColumnReverse = computedStyle && computedStyle.flexDirection === 'column-reverse';
        var stickToBottom = true;

        function scrollToBottom() {
            if (isColumnReverse) {
                list.scrollTop = 0;
            } else {
                list.scrollTop = list.scrollHeight;
            }
            stickToBottom = true;
        }

        function isNearBottom() {
            if (isColumnReverse) {
                return Math.abs(list.scrollTop) <= 50;
            }
            return (list.scrollHeight - list.clientHeight - list.scrollTop) <= 50;
        }

        function updateStickiness() {
            stickToBottom = isNearBottom();
        }

        function clearSearchFilter() {
            if (!list) return;
            list.querySelectorAll('.comment-item').forEach(function(item) {
                item.style.display = '';
            });
        }

        function filterCommentsByQuery(query) {
            if (!list) return 0;
            var normalized = query.toLowerCase();
            var matches = 0;
            list.querySelectorAll('.comment-item').forEach(function(item) {
                var contentEl = item.querySelector('.comment-content');
                var text = '';
                if (contentEl) {
                    text = contentEl.textContent || '';
                } else {
                    text = item.textContent || '';
                }
                if (text.toLowerCase().indexOf(normalized) !== -1) {
                    item.style.display = '';
                    matches += 1;
                } else {
                    item.style.display = 'none';
                }
            });
            return matches;
        }

        if (window.MutationObserver) {
            var listObserver = new MutationObserver(function(mutations) {
                var hasAddedNodes = mutations.some(function(mutation) {
                    return mutation.addedNodes && mutation.addedNodes.length > 0;
                });
                if (hasAddedNodes && stickToBottom) {
                    requestAnimationFrame(scrollToBottom);
                }
            });
            listObserver.observe(list, { childList: true });
        }

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
            if (manualTypingMessage) {
                if (ids.length === 0) {
                    typingIndicator.style.visibility = 'visible';
                    var messageEl = document.createElement('span');
                    messageEl.textContent = manualTypingMessage;
                    typingIndicator.appendChild(messageEl);
                    return;
                }
                manualTypingMessage = null;
            }
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
                clearManualTypingMessage();
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
                if (e.key === 'Enter' && !e.shiftKey) {
                    send(e);
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
            if (searchBtn) {
                searchBtn.addEventListener('click', function(e) {
                    e.preventDefault();
                    var query = textarea.value.trim();
                    if (!query) {
                        clearSearchFilter();
                        if (popup.dataset.searchEmptyText) {
                            setManualTypingMessage(popup.dataset.searchEmptyText);
                        } else {
                            clearManualTypingMessage();
                        }
                        return;
                    }
                    clearManualTypingMessage();
                    filterCommentsByQuery(query);
                    list.scrollTop = 0;
                });
            }
            if (window.handleCreativeCommentsClick) {
                document.removeEventListener('creative-comments-click', window.handleCreativeCommentsClick);
            }
            function onCreativeCommentsClick(e) {
                const btn = e.detail?.button;
                if (!btn) return;
                if (popup.style.display === 'block' && popup.dataset.creativeId === btn.dataset.creativeId) {
                    closePopup();
                    return;
                }
                openPopup(btn);
            }
            window.handleCreativeCommentsClick = onCreativeCommentsClick;
            document.addEventListener('creative-comments-click', onCreativeCommentsClick);
            window.attachCommentButtons = function() {};
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
                updateStickiness();
                const pos = list.scrollHeight - list.clientHeight + list.scrollTop;
                if (pos < 50) {
                    loadMoreComments();
                }
            });
            var currentPage = 1;
            var loadingMore = false;
            var allLoaded = false;

            function fetchCommentsPage(page) {
                return fetch(`/creatives/${popup.dataset.creativeId}/comments?page=${page}`)
                    .then(r => r.text());
            }

            markCommentsRead = function markCommentsRead() {
                fetch('/comment_read_pointers/update', {
                    method: 'POST',
                    headers: {
                        'X-CSRF-Token': document.querySelector('meta[name=csrf-token]').content,
                        'Content-Type': 'application/json'
                    },
                    body: JSON.stringify({ creative_id: popup.dataset.creativeId })
                });
            };

            function checkAllLoaded(html) {
                if ((html.match(/class="comment-item /g) || []).length < 10) {
                    allLoaded = true;
                }
            }

            loadInitialComments = function loadInitialComments(highlightId) {
                currentPage = 1;
                allLoaded = false;
                list.innerHTML = popup.dataset.loadingText;
                fetchCommentsPage(1).then(function(html) {
                    list.innerHTML = html;
                    clearManualTypingMessage();
                    clearSearchFilter();
                    renderMarkdown(list);
                    updatePosition();
                    if (!highlightId) {
                        requestAnimationFrame(function() {
                            scrollToBottom();
                            updateStickiness();
                        });
                    } else {
                        updateStickiness();
                    }
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
            };

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

            resetForm = function resetForm() {
                form.reset();
                editingId = null;
                submitBtn.innerHTML = defaultSubmitBtnHTML;
                if (cancelBtn) { cancelBtn.style.display = 'none'; }
                clearManualTypingMessage();
                clearSearchFilter();
            };

            let sending = false;
            const send = function(e) {
                e.preventDefault();
                if (sending || !textarea.value) return;
                clearManualTypingMessage();
                clearSearchFilter();
                sending = true;
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
                        const wasEditing = editingId;
                        const isPrivate = privateCheckbox && privateCheckbox.checked;
                        resetForm();
                        if (wasEditing) {
                            // UI automatically updated by turbo stream
                            var existing = document.getElementById(`comment_${wasEditing}`);
                            if (existing) {
                                markCommentsRead();
                            }
                        } else {
                            setTimeout(function() {
                                if (document.getElementById('no-comments')) {
                                    document.getElementById('no-comments').style.display = 'none';
                                }
                                if (isPrivate) {
                                    const l = document.getElementById('comments_list');
                                    l.insertAdjacentHTML('beforeend', html);
                                }
                                requestAnimationFrame(function() {
                                    scrollToBottom();
                                    updateStickiness();
                                });
                            }, 100)
                        }
                    })
                    .catch(e => { alert(e.message); })
                    .finally(() => { sending = false; });
            }

            submitBtn.addEventListener('click', send);
            // iOS에서 키보드 열림 중 click 유실 대비
            submitBtn.addEventListener('pointerup', (e)=>{ if (e.pointerType !== 'mouse') send(e); });
            submitBtn.addEventListener('touchend', (e)=>{ e.preventDefault(); send(e); }, {passive:false});

            form.onsubmit = send;
            // 이벤트 위임 방식으로 삭제 버튼 처리
            list.addEventListener('click', function(e) {
                var target = e.target instanceof Element ? e.target : e.target.parentElement;
                if (!target) return;

                var copyBtn = target.closest('.copy-comment-link-btn');
                if (copyBtn) {
                    e.preventDefault();
                    var url = copyBtn.getAttribute('data-comment-url');
                    var commentId = copyBtn.getAttribute('data-comment-id');
                    if (!url && commentId && popup.dataset.creativeId) {
                        var baseUrl = new URL(window.location.origin + '/creatives/' + popup.dataset.creativeId);
                        baseUrl.searchParams.set('comment_id', commentId);
                        baseUrl.hash = 'comment_' + commentId;
                        url = baseUrl.toString();
                    }
                    if (!url) { return; }
                    var commentElement = copyBtn.closest('.comment-item');
                    copyTextToClipboard(url)
                        .then(function() {
                            showCopyFeedback(commentElement, popup.dataset.copyLinkSuccessText);
                        })
                        .catch(function() {
                            showCopyFeedback(commentElement, popup.dataset.copyLinkErrorText);
                        });
                    return;
                }

                var editActionBtn = target.closest('.edit-comment-action-btn');
                if (editActionBtn) {
                    e.preventDefault();
                    openActionEditor(getActionContainer(editActionBtn));
                    return;
                }

                var cancelActionEditBtn = target.closest('.cancel-comment-action-edit-btn');
                if (cancelActionEditBtn) {
                    e.preventDefault();
                    closeActionEditor(getActionContainer(cancelActionEditBtn));
                    return;
                }

                if (target.classList.contains('delete-comment-btn')) {
                    e.preventDefault();
                    if (!confirm(popup.dataset.deleteConfirmText)) return;
                    var btn = target;
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
               } else if (target.classList.contains('convert-comment-btn')) {
                   e.preventDefault();
                    if (!confirm(popup.dataset.convertConfirmText)) return;
                   var btn = target;
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
                } else if (target.classList.contains('approve-comment-btn')) {
                    e.preventDefault();
                    var btn = target;
                    if (btn.disabled) return;
                    btn.disabled = true;
                    var commentId = btn.getAttribute('data-comment-id');
                    var creativeId = popup.dataset.creativeId;
                    fetch(`/creatives/${creativeId}/comments/${commentId}/approve`, {
                        method: 'POST',
                        headers: { 'X-CSRF-Token': document.querySelector('meta[name=csrf-token]').content }
                    }).then(function(r) {
                        if (r.ok) {
                            return r.text();
                        }
                        return r.json().then(function(j) {
                            throw new Error(j && j.error ? j.error : popup.dataset.approveErrorText);
                        }).catch(function(err) {
                            throw err instanceof Error ? err : new Error(popup.dataset.approveErrorText);
                        });
                    }).then(function(html) {
                        if (!html) { btn.disabled = false; return; }
                        var existing = document.getElementById(`comment_${commentId}`);
                        if (existing) {
                            existing.outerHTML = html;
                            var updated = document.getElementById(`comment_${commentId}`);
                            if (updated && popup.dataset.approveSuccessText) {
                                showCopyFeedback(updated, popup.dataset.approveSuccessText);
                            }
                        } else {
                            btn.disabled = false;
                        }
                    }).catch(function(e) {
                        btn.disabled = false;
                        alert(e && e.message ? e.message : popup.dataset.approveErrorText);
                    });
                } else if (target.classList.contains('edit-comment-btn')) {
                    e.preventDefault();
                    var btn = target;
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

            list.addEventListener('submit', function(e) {
                var formTarget = e.target;
                if (!(formTarget instanceof HTMLFormElement)) return;
                if (!formTarget.classList.contains('comment-action-edit-form')) return;
                e.preventDefault();
                var submitButton = formTarget.querySelector('.save-comment-action-btn');
                if (submitButton && submitButton.disabled) return;
                if (submitButton) { submitButton.disabled = true; }
                var textareaField = formTarget.querySelector('.comment-action-edit-textarea');
                if (!textareaField) {
                    if (submitButton) { submitButton.disabled = false; }
                    return;
                }
                var commentId = formTarget.getAttribute('data-comment-id');
                var creativeId = popup.dataset.creativeId;
                var payload = textareaField.value;
                fetch(`/creatives/${creativeId}/comments/${commentId}/update_action`, {
                    method: 'PATCH',
                    headers: {
                        'X-CSRF-Token': document.querySelector('meta[name=csrf-token]').content,
                        'Content-Type': 'application/json'
                    },
                    body: JSON.stringify({ comment: { action: payload } })
                }).then(function(r) {
                    if (r.ok) {
                        return r.text();
                    }
                    return r.json().then(function(j) {
                        throw new Error(j && j.error ? j.error : popup.dataset.actionUpdateErrorText);
                    }).catch(function(err) {
                        throw err instanceof Error ? err : new Error(popup.dataset.actionUpdateErrorText);
                    });
                }).then(function(html) {
                    if (!html) { return; }
                    var existing = document.getElementById(`comment_${commentId}`);
                    if (existing) {
                        existing.outerHTML = html;
                        var updated = document.getElementById(`comment_${commentId}`);
                        if (updated && popup.dataset.actionUpdateSuccessText) {
                            showCopyFeedback(updated, popup.dataset.actionUpdateSuccessText);
                        }
                    }
                }).catch(function(err) {
                    alert(err && err.message ? err.message : popup.dataset.actionUpdateErrorText);
                }).finally(function() {
                    if (submitButton) { submitButton.disabled = false; }
                });
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
