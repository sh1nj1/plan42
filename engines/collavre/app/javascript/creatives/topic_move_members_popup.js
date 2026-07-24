import csrfFetch from '../lib/api/csrf_fetch';

// After a topic is moved to another creative, TopicsController#move returns the
// members who had access on the source creative but not on the target. This
// module renders the (hidden) `#topic-move-members-modal` partial with those
// members and lets the user re-add them with one click. All user-facing text
// comes from the partial's i18n data-attributes — nothing is hardcoded here.

function getModal() {
  return document.getElementById('topic-move-members-modal');
}

function closeModal(modal) {
  modal.style.display = 'none';
  document.body.classList.remove('no-scroll');
  const list = modal.querySelector('#topic-move-members-list');
  if (list) list.innerHTML = '';
  const message = modal.querySelector('#topic-move-members-message');
  if (message) message.innerHTML = '';
}

function buildRow(modal, member) {
  const template = modal.querySelector('#topic-move-member-row');
  const row = template.content.firstElementChild.cloneNode(true);
  const user = member.user || {};

  const avatar = row.querySelector('.tmm-avatar');
  if (user.avatar_url && !user.default_avatar) {
    const img = document.createElement('img');
    img.src = user.avatar_url;
    img.alt = '';
    img.style.width = '100%';
    img.style.height = '100%';
    img.style.objectFit = 'cover';
    avatar.appendChild(img);
  } else {
    avatar.textContent = user.initial || '?';
  }

  row.querySelector('.tmm-name').textContent = user.name || user.email || '';
  row.querySelector('.tmm-email').textContent = user.email || '';

  const select = row.querySelector('.tmm-permission');
  if (member.permission) {
    const option = Array.from(select.options).find((o) => o.value === member.permission);
    if (option) select.value = member.permission;
  }

  row.dataset.userEmail = user.email || '';
  return row;
}

function setMessage(modal, text) {
  const message = modal.querySelector('#topic-move-members-message');
  if (message) message.textContent = text || '';
}

async function addSelected(modal, targetCreativeId) {
  const addBtn = modal.querySelector('#topic-move-members-add');
  const rows = Array.from(modal.querySelectorAll('.topic-move-member-row')).filter((row) => {
    const checkbox = row.querySelector('.tmm-checkbox');
    return checkbox && checkbox.checked && row.dataset.userEmail;
  });

  if (rows.length === 0) {
    closeModal(modal);
    return;
  }

  addBtn.disabled = true;
  setMessage(modal, addBtn.dataset.addingText || modal.dataset.addingText || '');

  const urlTemplate = modal.dataset.sharesUrlTemplate || modal.dataset.sharesUrl;
  const url = urlTemplate.replace('__CREATIVE_ID__', encodeURIComponent(targetCreativeId));

  let added = 0;
  let failed = 0;

  // Sequential so we reuse the existing per-user share endpoint (with all its
  // invitation / linked-creative / contact side effects) and keep ordering.
  for (const row of rows) {
    const status = row.querySelector('.tmm-status');
    const select = row.querySelector('.tmm-permission');
    const body = new FormData();
    body.append('user_email', row.dataset.userEmail);
    body.append('permission', select ? select.value : 'feedback');

    try {
      // eslint-disable-next-line no-await-in-loop
      const response = await csrfFetch(url, {
        method: 'POST',
        headers: { Accept: 'application/json' },
        body,
      });
      if (response.ok) {
        added += 1;
        if (status) status.textContent = '✓';
        row.style.opacity = '0.6';
      } else {
        failed += 1;
        if (status) status.textContent = '✗';
      }
    } catch (error) {
      failed += 1;
      if (status) status.textContent = '✗';
    }
  }

  if (failed === 0) {
    const template = added === 1
      ? (modal.dataset.addedOne || '')
      : (modal.dataset.addedOther || '');
    setMessage(modal, template.replace('__COUNT__', added));
    setTimeout(() => closeModal(modal), 1200);
  } else if (added === 0) {
    setMessage(modal, modal.dataset.failedText || '');
    addBtn.disabled = false;
  } else {
    const template = modal.dataset.partialText || '';
    setMessage(modal, template.replace('__ADDED__', added).replace('__FAILED__', failed));
    addBtn.disabled = false;
  }
}

export function showMissingMembersPopup({ members, targetCreativeId, targetCreativeName }) {
  if (!Array.isArray(members) || members.length === 0) return;
  const modal = getModal();
  if (!modal) return;

  const list = modal.querySelector('#topic-move-members-list');
  list.innerHTML = '';
  members.forEach((member) => list.appendChild(buildRow(modal, member)));

  const description = modal.querySelector('#topic-move-members-description');
  if (description) {
    const template = modal.dataset.descriptionTemplate || '';
    description.textContent = template.replace('__CREATIVE_NAME__', targetCreativeName || '');
  }

  setMessage(modal, '');
  const addBtn = modal.querySelector('#topic-move-members-add');
  addBtn.disabled = false;

  // (Re)wire controls. Using onclick keeps a single handler across re-opens.
  modal.querySelector('#topic-move-members-close').onclick = () => closeModal(modal);
  modal.querySelector('#topic-move-members-skip').onclick = () => closeModal(modal);
  modal.onclick = (event) => {
    if (event.target === modal) closeModal(modal);
  };
  addBtn.onclick = () => addSelected(modal, targetCreativeId);

  modal.style.display = 'flex';
  modal.style.alignItems = 'center';
  modal.style.justifyContent = 'center';
  document.body.classList.add('no-scroll');
}
