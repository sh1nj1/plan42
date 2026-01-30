let slackIntegrationInitialized = false;

if (!slackIntegrationInitialized) {
  slackIntegrationInitialized = true;

  document.addEventListener('turbo:load', function () {
    const openBtn = document.getElementById('slack-integration-btn');
    const modal = document.getElementById('slack-integration-modal');
    if (!openBtn || !modal) return;

    const statusEl = document.getElementById('slack-integration-status');
    const loginBtn = document.getElementById('slack-login-btn');
    const closeBtn = document.getElementById('close-slack-modal');
    const prevBtn = document.getElementById('slack-prev-btn');
    const nextBtn = document.getElementById('slack-next-btn');
    const finishBtn = document.getElementById('slack-finish-btn');
    const refreshBtn = document.getElementById('slack-refresh-btn');
    const errorEl = document.getElementById('slack-wizard-error');
    const connectedStatus = document.getElementById('slack-connected-status');
    const existingContainer = document.getElementById('slack-existing-connections');
    const existingList = document.getElementById('slack-existing-channel-list');
    const addChannelSection = document.getElementById('slack-add-channel-section');
    const addChannelBtn = document.getElementById('slack-add-channel-btn');
    const connectMessage = document.getElementById('slack-connect-message');
    const channelListEl = document.getElementById('slack-channel-list');
    const channelSummaryEl = document.getElementById('slack-channel-summary');

    let creativeId = null;
    let currentStep = 'connect';
    let hasExistingIntegration = false;
    let availableChannels = [];
    let selectedChannel = null;
    let existingLinks = [];

    function csrfToken() {
      return document.querySelector('meta[name="csrf-token"]')?.content;
    }

    function resetWizard() {
      currentStep = 'connect';
      hasExistingIntegration = false;
      availableChannels = [];
      selectedChannel = null;
      existingLinks = [];
      statusEl.textContent = '';
      errorEl.style.display = 'none';
      errorEl.textContent = '';
      if (connectedStatus) {
        connectedStatus.style.display = 'none';
      }
      if (existingContainer) {
        existingContainer.style.display = 'none';
      }
      if (existingList) {
        existingList.innerHTML = '';
      }
      if (addChannelSection) {
        addChannelSection.style.display = 'none';
      }
      if (connectMessage) {
        connectMessage.style.display = '';
      }
      if (loginBtn) loginBtn.style.display = 'inline-block';
      if (channelListEl) channelListEl.innerHTML = '';
      updateStep();
    }

    function updateStep() {
      ['connect', 'channels', 'summary']
        .forEach(function (step) {
          const el = document.getElementById(`slack-step-${step}`);
          if (!el) return;
          el.style.display = (step === currentStep) ? 'block' : 'none';
        });

      if (currentStep === 'connect') {
        prevBtn.style.display = 'none';
        if (refreshBtn) refreshBtn.style.display = 'none';
        // Hide Next button - use Add Channel button instead
        nextBtn.style.display = 'none';
        finishBtn.style.display = 'none';
      } else if (currentStep === 'channels') {
        prevBtn.style.display = 'block';
        prevBtn.disabled = false;
        if (refreshBtn) refreshBtn.style.display = 'block';
        nextBtn.style.display = 'block';
        nextBtn.disabled = !selectedChannel;
        finishBtn.style.display = 'none';
      } else if (currentStep === 'summary') {
        prevBtn.style.display = 'block';
        prevBtn.disabled = false;
        if (refreshBtn) refreshBtn.style.display = 'none';
        nextBtn.style.display = 'none';
        finishBtn.style.display = 'block';
        finishBtn.disabled = false;
      }
    }

    function showError(message) {
      errorEl.textContent = message;
      errorEl.style.display = 'block';
    }

    function clearError() {
      errorEl.style.display = 'none';
      errorEl.textContent = '';
    }

    function loadIntegrationStatus() {
      if (!creativeId) return;

      statusEl.textContent = modal.dataset.loading || 'Loading...';
      clearError();

      fetch(`/slack/creatives/${creativeId}/slack_integrations`, {
        method: 'GET',
        headers: {
          'X-CSRF-Token': csrfToken(),
          'Accept': 'application/json'
        }
      })
        .then(response => response.json())
        .then(data => {
          console.log('Slack integration status:', data);
          statusEl.textContent = '';

          if (data.connected) {
            availableChannels = data.channels || [];
            existingLinks = data.links || [];

            if (existingLinks.length > 0) {
              hasExistingIntegration = true;
              showExistingIntegration(existingLinks);
            } else {
              hasExistingIntegration = true;
              showConnectedNoLinks();
            }
          } else {
            hasExistingIntegration = false;
            if (connectMessage) connectMessage.textContent = modal.dataset.loginRequired;
          }
          updateStep();
        })
        .catch(error => {
          console.error('Error loading integration status:', error);
          statusEl.textContent = '';
          showError('Failed to load integration status');
        });
    }

    function showExistingIntegration(links) {
      if (!existingContainer || !existingList) return;

      existingList.innerHTML = '';
      links.forEach(function (link) {
        const li = document.createElement('li');
        li.style.cssText = 'display:flex;align-items:center;justify-content:space-between;padding:0.5em 0.75em;margin-bottom:0.5em;background:var(--color-bg-alt);border-radius:4px;';

        const channelInfo = document.createElement('div');
        channelInfo.innerHTML = `<strong>#${link.channel_name || link.channel_id}</strong>`;

        if (link.last_synced_at) {
          const syncInfo = document.createElement('span');
          syncInfo.textContent = ` (synced ${new Date(link.last_synced_at).toLocaleDateString()})`;
          syncInfo.style.cssText = 'color:var(--color-text-secondary);font-size:0.85em;margin-left:0.5em;';
          channelInfo.appendChild(syncInfo);
        }

        const deleteBtn = document.createElement('button');
        deleteBtn.type = 'button';
        deleteBtn.className = 'btn btn-sm btn-danger';
        deleteBtn.textContent = modal.dataset.deleteButtonLabel || 'Remove';
        deleteBtn.style.cssText = 'padding:0.25em 0.5em;font-size:0.8em;';
        deleteBtn.addEventListener('click', function () {
          performDeleteLink(link);
        });

        li.appendChild(channelInfo);
        li.appendChild(deleteBtn);
        existingList.appendChild(li);
      });

      if (connectMessage) connectMessage.style.display = 'none';
      if (loginBtn) loginBtn.style.display = 'none';
      if (connectedStatus) connectedStatus.style.display = 'block';
      existingContainer.style.display = 'block';

      // Show "Add Channel" button if connected and there are available channels
      if (availableChannels.length > 0 && addChannelSection) {
        addChannelSection.style.display = 'block';
        hasExistingIntegration = true;
      }
    }

    function showConnectedNoLinks() {
      if (connectMessage) connectMessage.style.display = 'none';
      if (loginBtn) loginBtn.style.display = 'none';
      if (connectedStatus) connectedStatus.style.display = 'block';
      if (existingContainer) existingContainer.style.display = 'none';

      // Show "Add Channel" button
      if (availableChannels.length > 0 && addChannelSection) {
        addChannelSection.style.display = 'block';
        // Change button text since there are no existing links
        if (addChannelBtn) {
          addChannelBtn.textContent = modal.dataset.addFirstChannel || 'Link a Slack Channel';
        }
        hasExistingIntegration = true;
      }
    }

    function performDeleteLink(link) {
      if (!confirm(modal.dataset.deleteConfirm)) return;

      const btn = event.target;
      btn.disabled = true;
      btn.textContent = '...';
      clearError();

      fetch(`/slack/creatives/${creativeId}/slack_integrations/${link.id}`, {
        method: 'DELETE',
        headers: {
          'X-CSRF-Token': csrfToken(),
          'Accept': 'application/json'
        }
      })
        .then(response => response.json())
        .then(data => {
          if (data.success) {
            // Remove the link from existingLinks and re-render
            existingLinks = existingLinks.filter(l => l.id !== link.id);
            if (existingLinks.length > 0) {
              showExistingIntegration(existingLinks);
            } else {
              showConnectedNoLinks();
            }
            statusEl.textContent = modal.dataset.deleteSuccess || 'Channel link removed';
            statusEl.style.color = 'green';
          } else {
            showError(data.message || data.error || 'Deletion failed');
            btn.disabled = false;
            btn.textContent = modal.dataset.deleteButtonLabel || 'Remove';
          }
        })
        .catch(error => {
          console.error('Delete error:', error);
          showError('Deletion failed');
          btn.disabled = false;
          btn.textContent = modal.dataset.deleteButtonLabel || 'Remove';
        });
    }

    function renderChannelList() {
      if (!channelListEl) return;

      channelListEl.innerHTML = '';

      if (availableChannels.length === 0) {
        channelListEl.innerHTML = '<p style="padding:0.5em;color:var(--color-text-secondary);">No channels available</p>';
        return;
      }

      availableChannels.forEach(function (channel) {
        const div = document.createElement('div');
        div.className = 'slack-channel-item';

        const isLinked = existingLinks.some(link => link.channel_id === channel.id);

        const linkedLabel = modal.dataset.linkedLabel || '(linked)';
        div.innerHTML = `
          <strong>#${channel.name}</strong>
          ${isLinked ? `<span style="color:green;margin-left:0.5em;">${linkedLabel}</span>` : ''}
        `;

        if (!isLinked) {
          div.addEventListener('click', function () {
            document.querySelectorAll('.slack-channel-item').forEach(el => {
              el.classList.remove('active');
            });
            div.classList.add('active');
            selectedChannel = channel;
            nextBtn.disabled = false;
          });
        } else {
          div.style.opacity = '0.6';
          div.style.cursor = 'not-allowed';
        }

        channelListEl.appendChild(div);
      });
    }

    function updateSummary() {
      if (channelSummaryEl && selectedChannel) {
        channelSummaryEl.textContent = `#${selectedChannel.name}`;
      }
    }

    function performLink() {
      if (!creativeId || !selectedChannel) {
        showError(modal.dataset.noCreative);
        return;
      }

      finishBtn.disabled = true;
      finishBtn.textContent = modal.dataset.linking || 'Linking...';
      clearError();

      fetch(`/slack/creatives/${creativeId}/slack_integrations`, {
        method: 'POST',
        headers: {
          'X-CSRF-Token': csrfToken(),
          'Content-Type': 'application/json',
          'Accept': 'application/json'
        },
        body: JSON.stringify({
          channel_id: selectedChannel.id,
          channel_name: selectedChannel.name
        })
      })
        .then(response => response.json())
        .then(data => {
          if (data.success) {
            statusEl.textContent = modal.dataset.successMessage || 'Channel linked successfully';
            statusEl.style.color = 'green';
            setTimeout(() => {
              modal.style.display = 'none';
              resetWizard();
            }, 2000);
          } else {
            showError(data.message || data.error || 'Failed to link channel');
          }
        })
        .catch(error => {
          console.error('Link error:', error);
          showError('Failed to link channel');
        })
        .finally(() => {
          finishBtn.disabled = false;
          finishBtn.textContent = modal.dataset.linkChannel || 'Link Channel';
        });
    }

    // Event listeners
    openBtn.addEventListener('click', function () {
      creativeId = this.dataset.creativeId;
      if (!creativeId) {
        alert(modal.dataset.noCreative);
        return;
      }
      modal.style.display = 'flex';
      resetWizard();
      loadIntegrationStatus();
    });

    closeBtn.addEventListener('click', function () {
      modal.style.display = 'none';
      resetWizard();
    });

    loginBtn.addEventListener('click', function (e) {
      e.preventDefault();
      console.log('Slack login button clicked');
      const width = parseInt(this.dataset.windowWidth) || 600;
      const height = parseInt(this.dataset.windowHeight) || 700;
      const left = (screen.width - width) / 2;
      const top = (screen.height - height) / 2;

      const authUrl = this.href;
      const authWindow = window.open(authUrl, 'slack-auth-window',
        `width=${width},height=${height},left=${left},top=${top},scrollbars=yes,resizable=yes`);

      if (authWindow) {
        console.log('Auth window opened');

        const checkClosed = setInterval(() => {
          if (authWindow.closed) {
            clearInterval(checkClosed);
            console.log('Auth window closed, reloading integration status');
            setTimeout(() => loadIntegrationStatus(), 1000);
          }
        }, 1000);
      }
    });

    prevBtn.addEventListener('click', function () {
      if (currentStep === 'channels') {
        currentStep = 'connect';
      } else if (currentStep === 'summary') {
        currentStep = 'channels';
      }
      updateStep();
    });

    nextBtn.addEventListener('click', function () {
      clearError();
      if (currentStep === 'connect') {
        currentStep = 'channels';
        renderChannelList();
      } else if (currentStep === 'channels') {
        if (!selectedChannel) {
          showError('Please select a channel');
          return;
        }
        updateSummary();
        currentStep = 'summary';
      }
      updateStep();
    });

    finishBtn.addEventListener('click', performLink);

    if (addChannelBtn) {
      addChannelBtn.addEventListener('click', function () {
        currentStep = 'channels';
        selectedChannel = null;
        renderChannelList();
        updateStep();
      });
    }

    if (refreshBtn) {
      refreshBtn.addEventListener('click', function () {
        refreshBtn.disabled = true;
        refreshBtn.textContent = modal.dataset.loading || 'Loading...';
        selectedChannel = null;

        fetch(`/slack/creatives/${creativeId}/slack_integrations`, {
          method: 'GET',
          headers: {
            'X-CSRF-Token': csrfToken(),
            'Accept': 'application/json'
          }
        })
          .then(response => response.json())
          .then(data => {
            if (data.connected) {
              availableChannels = data.channels || [];
              existingLinks = data.links || [];
              renderChannelList();
            }
          })
          .catch(error => {
            console.error('Error refreshing channels:', error);
            showError(modal.dataset.refreshError || 'Failed to refresh channels');
          })
          .finally(() => {
            refreshBtn.disabled = false;
            refreshBtn.textContent = modal.dataset.refresh || 'Refresh';
            updateStep();
          });
      });
    }

    modal.addEventListener('click', function (e) {
      if (e.target === modal) {
        modal.style.display = 'none';
        resetWizard();
      }
    });
  });
}
