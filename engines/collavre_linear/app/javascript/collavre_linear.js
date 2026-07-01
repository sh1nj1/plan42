// Linear integration modal opener.
//
// The core integrations menu renders a hidden `#linear-integration-btn` and a
// menu item whose click-target controller clicks that button. This wires the
// button click to show `#linear-integration-modal`, mirroring the GitHub engine
// (collavre_github.js) which does the same for its `github-integration-*` ids.
//
// Unlike GitHub's multi-step wizard, the Linear modal is fully server-rendered
// (connect / link / linked states via ERB), so this opener only needs to show
// and close the modal — the forms inside submit on their own.

let linearIntegrationInitialized = false;

if (!linearIntegrationInitialized) {
  linearIntegrationInitialized = true;

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
  });
}
