// Linear integration modal opener.
//
// The core integrations menu renders a hidden `#linear-integration-btn` and a
// menu item whose click-target controller clicks that button. This wires the
// button click to show `#linear-integration-modal`, mirroring the GitHub engine
// (collavre_github.js) which does the same for its `github-integration-*` ids.
//
// The modal is server-rendered (connect / link / linked states via ERB), but
// its forms POST to JSON endpoints — Turbo would treat the JSON reply as a
// failed navigation and leave the modal stuck in its old state. So we submit
// them via fetch() and reload on success, transitioning to the next state.

let linearIntegrationInitialized = false;

if (!linearIntegrationInitialized) {
  linearIntegrationInitialized = true;

  // The OAuth popup posts `linearConnected` to the opener when it closes.
  // Reload so the modal re-renders in the connected (link-a-project) state.
  // Bound to `window` once — it survives Turbo navigations, unlike the
  // per-navigation element listeners set up in turbo:load below.
  window.addEventListener('message', function (event) {
    if (event.origin !== window.location.origin) return;
    if (event.data && event.data.type === 'linearConnected') {
      window.location.reload();
    }
  });

  // Submit a modal form (link / resync / unlink) to its JSON endpoint and
  // reload on success. Honors data-confirm and surfaces server errors.
  function submitLinearModalForm(form, fallbackError) {
    const confirmMsg = form.dataset.confirm;
    if (confirmMsg && !window.confirm(confirmMsg)) return;

    const genericError = fallbackError || 'Linear request failed.';
    const token = document.querySelector('meta[name="csrf-token"]')?.content;
    fetch(form.action, {
      method: 'POST', // Rails method-override (_method field) handles DELETE
      headers: {
        Accept: 'application/json',
        'X-CSRF-Token': token || '',
        'X-Requested-With': 'XMLHttpRequest'
      },
      body: new FormData(form)
    })
      .then(async function (res) {
        let data = {};
        try { data = await res.json(); } catch (e) { /* non-JSON body */ }
        if (res.ok && data.success) {
          window.location.reload();
        } else {
          window.alert(data.error || data.warning || genericError);
        }
      })
      .catch(function () { window.alert(genericError); });
  }

  document.addEventListener('turbo:load', function () {
    const openBtn = document.getElementById('linear-integration-btn');
    const modal = document.getElementById('linear-integration-modal');
    if (!openBtn || !modal) return;

    const closeBtn = document.getElementById('close-linear-modal');

    function showModal() {
      modal.style.display = 'flex';
      document.body.classList.add('no-scroll');
    }

    function closeModal() {
      modal.style.display = 'none';
      document.body.classList.remove('no-scroll');
    }

    openBtn.addEventListener('click', function () {
      showModal();
    });

    closeBtn?.addEventListener('click', closeModal);

    modal.addEventListener('click', function (event) {
      if (event.target === modal) closeModal();
    });

    // OAuth connect: open the popup first, then submit the hidden form with the
    // native form.submit(). Turbo intercepts submit-button clicks (and would
    // fetch() the store_creative endpoint, then auto-follow its 302 to Linear's
    // cross-origin authorize URL → blocked by CORS). Native submit() is not
    // intercepted, so the popup navigates for real and the redirect follows.
    const connectBtn = document.getElementById('linear-connect-btn');
    const connectForm = document.getElementById('linear-connect-form');
    connectBtn?.addEventListener('click', function () {
      const w = parseInt(connectBtn.dataset.windowWidth, 10) || 620;
      const h = parseInt(connectBtn.dataset.windowHeight, 10) || 720;
      const left = window.screenX + (window.outerWidth - w) / 2;
      const top = window.screenY + (window.outerHeight - h) / 2;
      window.open('', 'linear-auth-window', `width=${w},height=${h},left=${left},top=${top}`);
      connectForm?.submit();
    });

    // Link / resync / unlink forms POST to JSON endpoints. Intercept their
    // submit (the connect form is excluded — it's submitted natively above and
    // form.submit() never fires this event) and drive them via fetch().
    modal.querySelectorAll('form').forEach(function (form) {
      if (form.id === 'linear-connect-form') return;
      form.addEventListener('submit', function (event) {
        event.preventDefault();
        submitLinearModalForm(form, modal.dataset.errorGeneric);
      });
    });
  });
}
