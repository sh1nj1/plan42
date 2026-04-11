import { filterChannels, reconcileSelection, buildChannelViewModels } from './slack_channel_list.js';
import { csrfToken, showError, clearError, updateStepVisibility, openOAuthPopup, fetchWithCsrf, setupModalClose } from 'collavre/modules/integration_wizard';

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
    const channelSearchEl = document.getElementById('slack-channel-search');
    const channelSummaryEl = document.getElementById('slack-channel-summary');

    let creativeId = null;
    let currentStep = 'connect';
    let hasExistingIntegration = false;
    let availableChannels = [];
    let selectedChannel = null;
    let existingLinks = [];

    function resetWizard() {
      currentStep = 'connect';
      hasExistingIntegration = false;
      availableChannels = [];
      selectedChannel = null;
      existingLinks = [];
      statusEl.textContent = '';
      clearError(errorEl);
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
      updateStepVisibility(currentStep, ['connect', 'channels', 'summary'], 'slack-step');

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

    function loadIntegrationStatus() {
      if (!creativeId) return;

      statusEl.textContent = modal.dataset.loading || 'Loading...';
      clearError(errorEl);

      fetchWithCsrf(`/slack/creatives/${creativeId}/slack_integrations`)
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
          showError(errorEl, 'Failed to load integration status');
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

      // 1:1 relationship: hide "Add Channel" button if already linked
      if (addChannelSection) {
        addChannelSection.style.display = 'none';
      }
      hasExistingIntegration = true;
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
      clearError(errorEl);

      fetchWithCsrf(`/slack/creatives/${creativeId}/slack_integrations/${link.id}`, { method: 'DELETE' })
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
            showError(errorEl, data.message || data.error || 'Deletion failed');
            btn.disabled = false;
            btn.textContent = modal.dataset.deleteButtonLabel || 'Remove';
          }
        })
        .catch(error => {
          console.error('Delete error:', error);
          showError(errorEl, 'Deletion failed');
          btn.disabled = false;
          btn.textContent = modal.dataset.deleteButtonLabel || 'Remove';
        });
    }

    function renderChannelList(filter) {
      if (!channelListEl) return;

      channelListEl.innerHTML = '';

      if (availableChannels.length === 0) {
        channelListEl.innerHTML = `<p style="padding:0.5em;color:var(--color-text-secondary);">${modal.dataset.noChannelsAvailable || 'No channels available'}</p>`;
        return;
      }

      const filtered = filterChannels(availableChannels, filter);

      // Clear selection if the selected channel is not in the filtered results
      selectedChannel = reconcileSelection(selectedChannel, filtered);
      nextBtn.disabled = !selectedChannel;

      if (filtered.length === 0) {
        channelListEl.innerHTML = `<p style="padding:0.5em;color:var(--color-text-secondary);">${modal.dataset.noMatchingChannels || 'No matching channels'}</p>`;
        return;
      }

      const viewModels = buildChannelViewModels(filtered, existingLinks, selectedChannel);

      viewModels.forEach(function ({ channel, isLinked, isSelected }) {
        const div = document.createElement('div');
        div.className = 'slack-channel-item';

        const linkedLabel = modal.dataset.linkedLabel || '(linked)';
        div.innerHTML = `
          <strong>#${channel.name}</strong>
          ${isLinked ? `<span style="color:green;margin-left:0.5em;">${linkedLabel}</span>` : ''}
        `;

        if (isSelected) {
          div.classList.add('active');
        }

        if (!isLinked) {
          div.addEventListener('click', function () {
            channelListEl.querySelectorAll('.slack-channel-item').forEach(el => {
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
        showError(errorEl, modal.dataset.noCreative);
        return;
      }

      finishBtn.disabled = true;
      finishBtn.textContent = modal.dataset.linking || 'Linking...';
      clearError(errorEl);

      fetchWithCsrf(`/slack/creatives/${creativeId}/slack_integrations`, {
        method: 'POST',
        body: {
          channel_id: selectedChannel.id,
          channel_name: selectedChannel.name
        }
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
            showError(errorEl, data.message || data.error || 'Failed to link channel');
          }
        })
        .catch(error => {
          console.error('Link error:', error);
          showError(errorEl, 'Failed to link channel');
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

    setupModalClose(modal, closeBtn, resetWizard);

    loginBtn.addEventListener('click', function (e) {
      e.preventDefault();
      console.log('Slack login button clicked');
      openOAuthPopup('slack-auth-window', {
        width: parseInt(this.dataset.windowWidth) || 600,
        height: parseInt(this.dataset.windowHeight) || 700,
        url: this.href,
        onClose: function () {
          console.log('Auth window closed, reloading integration status');
          loadIntegrationStatus();
        }
      });
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
      clearError(errorEl);
      if (currentStep === 'connect') {
        currentStep = 'channels';
        if (channelSearchEl) channelSearchEl.value = '';
        renderChannelList();
      } else if (currentStep === 'channels') {
        if (!selectedChannel) {
          showError(errorEl, 'Please select a channel');
          return;
        }
        updateSummary();
        currentStep = 'summary';
      }
      updateStep();
    });

    finishBtn.addEventListener('click', performLink);

    if (channelSearchEl) {
      channelSearchEl.addEventListener('input', function () {
        renderChannelList(this.value);
      });
    }

    if (addChannelBtn) {
      addChannelBtn.addEventListener('click', function () {
        currentStep = 'channels';
        selectedChannel = null;
        if (channelSearchEl) channelSearchEl.value = '';
        renderChannelList();
        updateStep();
      });
    }

    if (refreshBtn) {
      refreshBtn.addEventListener('click', function () {
        refreshBtn.disabled = true;
        refreshBtn.textContent = modal.dataset.loading || 'Loading...';
        selectedChannel = null;

        fetchWithCsrf(`/slack/creatives/${creativeId}/slack_integrations`)
          .then(response => response.json())
          .then(data => {
            if (data.connected) {
              availableChannels = data.channels || [];
              existingLinks = data.links || [];
              renderChannelList(channelSearchEl ? channelSearchEl.value : '');
            }
          })
          .catch(error => {
            console.error('Error refreshing channels:', error);
            showError(errorEl, modal.dataset.refreshError || 'Failed to refresh channels');
          })
          .finally(() => {
            refreshBtn.disabled = false;
            refreshBtn.textContent = modal.dataset.refresh || 'Refresh';
            updateStep();
          });
      });
    }

  });

  // Slack badge for comments popup
  // Store references for cleanup to avoid handler accumulation across popup opens
  let slackBadgeClickHandler = null;
  let slackDocumentClickHandler = null;
  let slackBadgeRequestId = 0; // Guard against stale async responses

  document.addEventListener('comments-popup:opened', async function (event) {
    const { creativeId, badgeContainer } = event.detail;
    if (!badgeContainer || !creativeId) return;

    // Increment request id to invalidate any in-flight fetch
    const currentRequestId = ++slackBadgeRequestId;

    // Create or find slack badge element
    let badge = badgeContainer.querySelector('[data-slack-badge]');
    if (!badge) {
      badge = document.createElement('span');
      badge.setAttribute('data-slack-badge', '');
      badge.className = 'slack-channel-badge';
      badgeContainer.appendChild(badge);
    }

    // Clean up previous handlers before re-registering
    if (slackBadgeClickHandler) {
      badge.removeEventListener('click', slackBadgeClickHandler);
      slackBadgeClickHandler = null;
    }
    if (slackDocumentClickHandler) {
      document.removeEventListener('click', slackDocumentClickHandler);
      slackDocumentClickHandler = null;
    }

    // Remove any existing tooltip
    const existingTooltip = badgeContainer.querySelector('[data-slack-tooltip]');
    if (existingTooltip) existingTooltip.remove();

    // Hide badge initially
    badge.style.display = 'none';
    badge.textContent = '';

    try {
      const response = await fetch(`/slack/creatives/${creativeId}/slack_integrations/badge`, {
        headers: { Accept: 'application/json' }
      });

      // Discard response if a newer popup open has occurred
      if (currentRequestId !== slackBadgeRequestId) return;

      if (!response.ok) return;

      const data = await response.json();
      if (data.links && data.links.length > 0) {
        badge.textContent = 'Slack';
        badge.style.display = 'inline-block';
        badge.title = data.links.map(link => `#${link.channel_name}`).join(', ');

        // Create tooltip element for click display
        const tooltip = document.createElement('span');
        tooltip.setAttribute('data-slack-tooltip', '');
        tooltip.className = 'slack-channel-tooltip';
        tooltip.textContent = data.links.map(link => `#${link.channel_name}`).join(', ');
        badgeContainer.appendChild(tooltip);

        slackBadgeClickHandler = function (e) {
          e.stopPropagation();
          tooltip.classList.toggle('visible');
        };
        badge.addEventListener('click', slackBadgeClickHandler);

        // Close tooltip when clicking elsewhere
        slackDocumentClickHandler = function () {
          tooltip.classList.remove('visible');
        };
        document.addEventListener('click', slackDocumentClickHandler);
      }
    } catch (error) {
      console.warn('Failed to load Slack badge:', error);
    }
  });

  document.addEventListener('comments-popup:closed', function (event) {
    const { badgeContainer } = event.detail;
    if (!badgeContainer) return;

    // Invalidate any in-flight badge fetch so late responses are discarded
    slackBadgeRequestId++;

    const badge = badgeContainer.querySelector('[data-slack-badge]');
    if (badge) {
      badge.style.display = 'none';
      badge.textContent = '';
      if (slackBadgeClickHandler) {
        badge.removeEventListener('click', slackBadgeClickHandler);
        slackBadgeClickHandler = null;
      }
    }
    if (slackDocumentClickHandler) {
      document.removeEventListener('click', slackDocumentClickHandler);
      slackDocumentClickHandler = null;
    }
    const tooltip = badgeContainer.querySelector('[data-slack-tooltip]');
    if (tooltip) tooltip.remove();
  });
}
