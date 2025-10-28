let githubIntegrationInitialized = false;

if (!githubIntegrationInitialized) {
  githubIntegrationInitialized = true;

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
    const promptInput = document.getElementById('github-gemini-prompt');
    const errorEl = document.getElementById('github-wizard-error');
    const webhookUrlLabel = modal.dataset.webhookUrlLabel || 'Webhook URL';
    const webhookSecretLabel = modal.dataset.webhookSecretLabel || 'Webhook secret';
    const existingContainer = document.getElementById('github-existing-connections');
    const existingList = document.getElementById('github-existing-repo-list');
    const deleteBtn = document.getElementById('github-delete-btn');
    const connectMessage = document.getElementById('github-connect-message');
    const existingMessage = modal.dataset.existingMessage || '이미 연동된 Repository가 있습니다.';
    const deleteConfirm = modal.dataset.deleteConfirm || 'Github 연동을 삭제하시겠습니까?';
    const deleteSuccess = modal.dataset.deleteSuccess || 'Github 연동이 삭제되었습니다.';
    const deleteError = modal.dataset.deleteError || 'Github 연동을 삭제하지 못했습니다.';
    const deleteSelectWarning = modal.dataset.deleteSelectWarning || '삭제할 Repository를 선택하세요.';

    let creativeId = null;
    let currentStep = 'connect';
    let organizations = [];
    let selectedOrg = null;
    let selectedRepos = new Set();
    let webhookDetails = {};
    let geminiPrompt = '';
    let hasExistingIntegration = false;
    let selectedReposForDeletion = new Set();

    function csrfToken() {
      return document.querySelector('meta[name="csrf-token"]')?.content;
    }

    function resetWizard() {
      currentStep = 'connect';
      organizations = [];
      selectedOrg = null;
      selectedRepos = new Set();
      webhookDetails = {};
      geminiPrompt = '';
      hasExistingIntegration = false;
      selectedReposForDeletion = new Set();
      statusEl.textContent = '';
      errorEl.style.display = 'none';
      errorEl.textContent = '';
      if (summaryInstructions) summaryInstructions.style.display = 'none';
      if (promptInput) promptInput.value = '';
      if (existingContainer) {
        existingContainer.style.display = 'none';
      }
      if (existingList) {
        existingList.innerHTML = '';
      }
      if (connectMessage) {
        connectMessage.style.display = '';
      }
      if (deleteBtn) deleteBtn.style.display = 'none';
      updateDeleteButtonState();
      if (loginBtn) loginBtn.style.display = 'inline-block';
      updateStep();
    }

    function updateDeleteButtonState() {
      if (!deleteBtn) return;
      deleteBtn.disabled = selectedReposForDeletion.size === 0;
    }

    function updateStep() {
      ['connect', 'organization', 'repositories', 'summary', 'prompt']
        .forEach(function (step) {
          const el = document.getElementById(`github-step-${step}`);
          if (!el) return;
          el.style.display = (step === currentStep) ? 'block' : 'none';
        });

      if (currentStep === 'connect') {
        prevBtn.style.display = 'none';
        if (hasExistingIntegration) {
          nextBtn.style.display = 'block';
          nextBtn.disabled = false;
        } else {
          nextBtn.style.display = 'none';
        }
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
        nextBtn.style.display = 'block';
        nextBtn.disabled = false;
        finishBtn.style.display = 'none';
        updateSummary();
      } else if (currentStep === 'prompt') {
        prevBtn.style.display = 'block';
        nextBtn.style.display = 'none';
        finishBtn.style.display = 'block';
        if (promptInput) promptInput.focus();
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
            hasExistingIntegration = false;
            renderExistingConnections([]);
            if (connectMessage) connectMessage.style.display = '';
            if (loginBtn) loginBtn.style.display = 'inline-block';
            currentStep = 'connect';
            updateStep();
            return;
          }
          selectedRepos = new Set(data.selected_repositories || []);
          webhookDetails = data.webhooks || {};
          geminiPrompt = data.github_gemini_prompt || '';
          hasExistingIntegration = selectedRepos.size > 0;
          if (promptInput) promptInput.value = geminiPrompt;
          if (loginBtn) loginBtn.style.display = 'none';
          renderExistingConnections(Array.from(selectedRepos));

          if (hasExistingIntegration) {
            statusEl.textContent = existingMessage;
            if (connectMessage) connectMessage.style.display = 'none';
            currentStep = 'connect';
            updateStep();
          } else {
            statusEl.textContent = data.account && data.account.login ?
              `${data.account.login} 님의 Github 계정과 연동됩니다.` : '';
            if (connectMessage) connectMessage.style.display = 'none';
            selectedOrg = null;
            organizations = [];
            currentStep = 'organization';
            updateStep();
            loadOrganizations();
          }
        })
        .catch(function () {
          showError('Github 연동 정보를 불러오지 못했습니다.');
        });
    }

    function renderExistingConnections(repos) {
      if (!existingContainer || !existingList) return;
      existingList.innerHTML = '';
      selectedReposForDeletion = new Set();
      if (!repos || !repos.length) {
        existingContainer.style.display = 'none';
        if (deleteBtn) {
          deleteBtn.style.display = 'none';
          updateDeleteButtonState();
        }
        return;
      }

      repos.forEach(function (fullName) {
        const li = document.createElement('li');
        li.style.display = 'flex';
        li.style.alignItems = 'center';
        li.style.gap = '0.5em';
        li.style.marginBottom = '0.4em';
        li.style.listStyle = 'none';

        const label = document.createElement('label');
        label.style.display = 'flex';
        label.style.alignItems = 'center';
        label.style.gap = '0.5em';
        label.style.cursor = 'pointer';
        label.style.flex = '1';

        const checkbox = document.createElement('input');
        checkbox.type = 'checkbox';
        checkbox.value = fullName;
        checkbox.className = 'github-existing-repo-checkbox';
        checkbox.addEventListener('change', function () {
          if (checkbox.checked) {
            selectedReposForDeletion.add(fullName);
          } else {
            selectedReposForDeletion.delete(fullName);
          }
          updateDeleteButtonState();
        });

        const nameSpan = document.createElement('span');
        nameSpan.textContent = fullName;
        nameSpan.style.flex = '1';

        label.appendChild(checkbox);
        label.appendChild(nameSpan);
        li.appendChild(label);
        existingList.appendChild(li);
      });

      existingContainer.style.display = 'block';
      if (deleteBtn) {
        deleteBtn.style.display = 'inline-flex';
        updateDeleteButtonState();
      }
      if (loginBtn) loginBtn.style.display = 'none';
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
      if (repoList) {
        repoList.textContent = '...';
      }
      const params = new URLSearchParams({ organization: selectedOrg });
      if (creativeId) params.append('creative_id', creativeId);
      fetch(`/github/account/repositories?${params.toString()}`, { headers: { Accept: 'application/json' } })
        .then(function (response) { return response.json(); })
        .then(function (data) {
          renderRepositories(data.repositories || []);
        })
        .catch(function () {
          if (repoList) repoList.textContent = '';
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
      if (promptInput) payload.github_gemini_prompt = promptInput.value;
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
          geminiPrompt = result.body.github_gemini_prompt || '';
          if (promptInput) promptInput.value = geminiPrompt;
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
      } else if (currentStep === 'prompt') {
        currentStep = 'summary';
      }
      updateStep();
      if (currentStep === 'organization' && organizations.length === 0) loadOrganizations();
      if (currentStep === 'repositories') loadRepositories();
    });

    nextBtn.addEventListener('click', function () {
      clearError();
      if (currentStep === 'connect') {
        currentStep = 'organization';
        updateStep();
        loadOrganizations();
      } else if (currentStep === 'organization') {
        currentStep = 'repositories';
        updateStep();
        loadRepositories();
      } else if (currentStep === 'repositories') {
        currentStep = 'summary';
        updateStep();
      } else if (currentStep === 'summary') {
        currentStep = 'prompt';
        updateStep();
        if (promptInput) promptInput.focus();
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

    deleteBtn?.addEventListener('click', function () {
      if (!creativeId) {
        alert(modal.dataset.noCreative);
        return;
      }
      clearError();
      const selectedToDelete = Array.from(selectedReposForDeletion);
      if (!selectedToDelete.length) {
        showError(deleteSelectWarning);
        return;
      }
      if (!window.confirm(deleteConfirm)) return;

      fetch(`/creatives/${creativeId}/github_integration`, {
        method: 'DELETE',
        headers: {
          'Content-Type': 'application/json',
          'X-CSRF-Token': csrfToken()
        },
        body: JSON.stringify({ repositories: selectedToDelete })
      })
        .then(function (response) { return response.json().then(function (body) { return { ok: response.ok, body: body }; }); })
        .then(function (result) {
          if (!result.ok) {
            showError(result.body.error || deleteError);
            return;
          }

          selectedRepos = new Set(result.body.selected_repositories || []);
          webhookDetails = result.body.webhooks || {};
          geminiPrompt = result.body.github_gemini_prompt || '';
          hasExistingIntegration = selectedRepos.size > 0;
          if (promptInput) promptInput.value = geminiPrompt;
          renderExistingConnections(Array.from(selectedRepos));
          updateSummary();
          statusEl.textContent = deleteSuccess;

          if (!hasExistingIntegration) {
            selectedOrg = null;
            organizations = [];
            currentStep = 'organization';
            updateStep();
            loadOrganizations();
          }
        })
        .catch(function () {
          showError(deleteError);
        });
    });

    window.addEventListener('message', function (event) {
      if (event.origin !== window.location.origin) return;
      if (event.data && event.data.type === 'githubConnected') {
        fetchStatus();
      }
    });
  });
}
