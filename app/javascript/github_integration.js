if (!window.githubIntegrationInitialized) {
  window.githubIntegrationInitialized = true;

  document.addEventListener('turbo:load', function () {
    const openBtn = document.getElementById('github-integration-btn');
    const modal = document.getElementById('github-integration-modal');
    if (!openBtn || !modal) return;

    const statusEl = document.getElementById('github-integration-status');
    const loginBtn = document.getElementById('github-login-btn');
    const loginForm = document.getElementById('github-login-form');
    const closeBtn = document.getElementById('close-github-modal');
    const prevBtn = document.getElementById('github-prev-btn');
    const nextBtn = document.getElementById('github-next-btn');
    const finishBtn = document.getElementById('github-finish-btn');
    const orgList = document.getElementById('github-organization-list');
    const repoList = document.getElementById('github-repository-list');
    const summaryList = document.getElementById('github-selected-repos');
    const summaryEmpty = document.getElementById('github-summary-empty');
    const summaryInstructions = document.getElementById('github-webhook-instructions');
    const errorEl = document.getElementById('github-wizard-error');
    const webhookUrlLabel = modal.dataset.webhookUrlLabel || 'Webhook URL';
    const webhookSecretLabel = modal.dataset.webhookSecretLabel || 'Webhook secret';

    let creativeId = null;
    let currentStep = 'connect';
    let organizations = [];
    let selectedOrg = null;
    let selectedRepos = new Set();
    let webhookDetails = {};

    function csrfToken() {
      return document.querySelector('meta[name="csrf-token"]')?.content;
    }

    function resetWizard() {
      currentStep = 'connect';
      organizations = [];
      selectedOrg = null;
      selectedRepos = new Set();
      webhookDetails = {};
      statusEl.textContent = '';
      errorEl.style.display = 'none';
      errorEl.textContent = '';
      if (summaryInstructions) summaryInstructions.style.display = 'none';
      updateStep();
    }

    function updateStep() {
      ['github-step-connect', 'github-step-organization', 'github-step-repositories', 'github-step-summary']
        .forEach(function (id) {
          const el = document.getElementById(id);
          if (!el) return;
          el.style.display = (id === `github-step-${currentStep}`) ? 'block' : 'none';
        });

      if (currentStep === 'connect') {
        prevBtn.style.display = 'none';
        nextBtn.style.display = 'none';
        finishBtn.style.display = 'none';
      } else if (currentStep === 'organization') {
        prevBtn.style.display = 'block';
        nextBtn.style.display = 'block';
        nextBtn.disabled = !selectedOrg;
        finishBtn.style.display = 'none';
      } else if (currentStep === 'repositories') {
        prevBtn.style.display = 'block';
        nextBtn.style.display = 'block';
        nextBtn.disabled = false;
        finishBtn.style.display = 'none';
      } else if (currentStep === 'summary') {
        prevBtn.style.display = 'block';
        nextBtn.style.display = 'none';
        finishBtn.style.display = 'block';
        updateSummary();
      }
    }

    function showModal() {
      modal.style.display = 'flex';
      document.body.classList.add('no-scroll');
    }

    function closeModal() {
      modal.style.display = 'none';
      document.body.classList.remove('no-scroll');
    }

    function showError(message) {
      if (!message) return;
      errorEl.textContent = message;
      errorEl.style.display = 'block';
    }

    function clearError() {
      errorEl.textContent = '';
      errorEl.style.display = 'none';
    }

    function fetchStatus() {
      if (!creativeId) {
        showError(modal.dataset.noCreative);
        return;
      }
      clearError();
      fetch(`/creatives/${creativeId}/github_integration`, { headers: { Accept: 'application/json' } })
        .then(function (response) { return response.json(); })
        .then(function (data) {
          if (!data.connected) {
            statusEl.textContent = modal.dataset.loginRequired;
            currentStep = 'connect';
            updateStep();
            return;
          }
          statusEl.textContent = data.account && data.account.login ?
            `${data.account.login} 님의 Github 계정과 연동됩니다.` : '';
          selectedRepos = new Set(data.selected_repositories || []);
          webhookDetails = data.webhooks || {};
          currentStep = 'organization';
          updateStep();
          loadOrganizations();
        })
        .catch(function () {
          showError('Github 연동 정보를 불러오지 못했습니다.');
        });
    }

    function loadOrganizations() {
      fetch('/github/account/organizations', { headers: { Accept: 'application/json' } })
        .then(function (response) { return response.json(); })
        .then(function (data) {
          organizations = data.organizations || [];
          renderOrganizations();
        })
        .catch(function () {
          showError('Organization 목록을 불러오지 못했습니다.');
        });
    }

    function renderOrganizations() {
      if (!orgList) return;
      orgList.innerHTML = '';
      if (!organizations.length) {
        const p = document.createElement('p');
        p.textContent = '조회할 수 있는 Organization이 없습니다.';
        orgList.appendChild(p);
        return;
      }
      organizations.forEach(function (org) {
        const label = document.createElement('label');
        label.style.display = 'block';
        label.style.marginBottom = '0.5em';

        const input = document.createElement('input');
        input.type = 'radio';
        input.name = 'github-organization';
        input.value = org.login;
        input.checked = selectedOrg === org.login;
        input.addEventListener('change', function () {
          selectedOrg = org.login;
          nextBtn.disabled = false;
        });

        const span = document.createElement('span');
        span.textContent = org.name || org.login;

        label.appendChild(input);
        label.appendChild(document.createTextNode(' '));
        label.appendChild(span);
        orgList.appendChild(label);
      });
      nextBtn.disabled = !selectedOrg;
    }

    function loadRepositories() {
      if (!selectedOrg) return;
      clearError();
      const params = new URLSearchParams({ organization: selectedOrg });
      if (creativeId) params.append('creative_id', creativeId);
      fetch(`/github/account/repositories?${params.toString()}`, { headers: { Accept: 'application/json' } })
        .then(function (response) { return response.json(); })
        .then(function (data) {
          renderRepositories(data.repositories || []);
        })
        .catch(function () {
          showError('Repository 목록을 불러오지 못했습니다.');
        });
    }

    function renderRepositories(repositories) {
      if (!repoList) return;
      repoList.innerHTML = '';
      if (!repositories.length) {
        const p = document.createElement('p');
        p.textContent = '선택 가능한 Repository가 없습니다.';
        repoList.appendChild(p);
        return;
      }
      repositories.forEach(function (repo) {
        const label = document.createElement('label');
        label.style.display = 'block';
        label.style.marginBottom = '0.5em';

        const input = document.createElement('input');
        input.type = 'checkbox';
        input.value = repo.full_name;
        input.checked = selectedRepos.has(repo.full_name) || repo.selected;
        input.addEventListener('change', function () {
          if (input.checked) {
            selectedRepos.add(repo.full_name);
          } else {
            selectedRepos.delete(repo.full_name);
          }
        });

        const span = document.createElement('span');
        span.textContent = repo.full_name;

        label.appendChild(input);
        label.appendChild(document.createTextNode(' '));
        label.appendChild(span);
        repoList.appendChild(label);
      });
    }

    function updateSummary() {
      if (!summaryList) return;
      summaryList.innerHTML = '';
      const repos = Array.from(selectedRepos);
      if (!repos.length) {
        summaryEmpty.style.display = 'block';
        if (summaryInstructions) summaryInstructions.style.display = 'none';
        return;
      }
      summaryEmpty.style.display = 'none';
      if (summaryInstructions) summaryInstructions.style.display = 'block';
      repos.forEach(function (fullName) {
        const li = document.createElement('li');
        const title = document.createElement('strong');
        title.textContent = fullName;
        li.appendChild(title);

        const details = webhookDetails[fullName] || {};
        const urlValue = details.url;
        const secretValue = details.secret;

        if (urlValue || secretValue) {
          const detailsContainer = document.createElement('div');
          detailsContainer.className = 'github-webhook-details';
          detailsContainer.style.marginTop = '0.3em';

          if (urlValue) {
            detailsContainer.appendChild(createWebhookDetail(webhookUrlLabel, urlValue));
          }

          if (secretValue) {
            detailsContainer.appendChild(createWebhookDetail(webhookSecretLabel, secretValue));
          }

          li.appendChild(detailsContainer);
        }

        summaryList.appendChild(li);
      });
    }

    function createWebhookDetail(label, value) {
      const row = document.createElement('div');
      row.className = 'github-webhook-detail-row';

      const labelEl = document.createElement('span');
      labelEl.textContent = `${label}: `;
      labelEl.style.fontWeight = '600';

      const codeEl = document.createElement('code');
      codeEl.textContent = value;

      row.appendChild(labelEl);
      row.appendChild(codeEl);

      return row;
    }

    function saveSelection() {
      clearError();
      const payload = { repositories: Array.from(selectedRepos) };
      fetch(`/creatives/${creativeId}/github_integration`, {
        method: 'PATCH',
        headers: {
          'Content-Type': 'application/json',
          'X-CSRF-Token': csrfToken()
        },
        body: JSON.stringify(payload)
      })
        .then(function (response) { return response.json().then(function (body) { return { ok: response.ok, body: body }; }); })
        .then(function (result) {
          if (!result.ok) {
            showError(result.body.error || '연동 저장 중 오류가 발생했습니다.');
            return;
          }
          selectedRepos = new Set(result.body.selected_repositories || []);
          webhookDetails = result.body.webhooks || {};
          updateSummary();
          alert(modal.dataset.successMessage);
        })
        .catch(function () {
          showError('연동 정보를 저장하지 못했습니다.');
        });
    }

    openBtn.addEventListener('click', function () {
      creativeId = openBtn.dataset.creativeId;
      if (!creativeId) {
        alert(modal.dataset.noCreative);
        return;
      }
      resetWizard();
      showModal();
      fetchStatus();
    });

    closeBtn?.addEventListener('click', closeModal);
    modal.addEventListener('click', function (event) {
      if (event.target === modal) closeModal();
    });

    prevBtn.addEventListener('click', function () {
      clearError();
      if (currentStep === 'organization') {
        currentStep = 'connect';
      } else if (currentStep === 'repositories') {
        currentStep = 'organization';
      } else if (currentStep === 'summary') {
        currentStep = 'repositories';
      }
      updateStep();
      if (currentStep === 'organization' && organizations.length === 0) loadOrganizations();
      if (currentStep === 'repositories') loadRepositories();
    });

    nextBtn.addEventListener('click', function () {
      clearError();
      if (currentStep === 'organization') {
        currentStep = 'repositories';
        updateStep();
        loadRepositories();
      } else if (currentStep === 'repositories') {
        currentStep = 'summary';
        updateStep();
      }
    });

    finishBtn.addEventListener('click', function () {
      saveSelection();
    });

    loginBtn.addEventListener('click', function () {
      const width = Number(loginBtn.dataset.windowWidth) || 600;
      const height = Number(loginBtn.dataset.windowHeight) || 700;
      const left = window.screenX + Math.max(0, (window.outerWidth - width) / 2);
      const top = window.screenY + Math.max(0, (window.outerHeight - height) / 2);
      window.open('', 'github-auth-window', `width=${width},height=${height},left=${left},top=${top}`);
      loginForm.submit();
    });

    window.addEventListener('message', function (event) {
      if (event.origin !== window.location.origin) return;
      if (event.data && event.data.type === 'githubConnected') {
        fetchStatus();
      }
    });
  });
}
