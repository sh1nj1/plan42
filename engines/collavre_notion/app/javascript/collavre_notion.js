import { csrfToken, showError, clearError, updateStepVisibility, openOAuthPopup, fetchWithCsrf, setupModalClose } from 'collavre/modules/integration_wizard';

let notionIntegrationInitialized = false;

if (!notionIntegrationInitialized) {
  notionIntegrationInitialized = true;

  document.addEventListener('turbo:load', function () {
    const openBtn = document.getElementById('notion-integration-btn');
    const modal = document.getElementById('notion-integration-modal');
    if (!openBtn || !modal) return;

    const statusEl = document.getElementById('notion-integration-status');
    const loginBtn = document.getElementById('notion-login-btn');
    const loginForm = document.getElementById('notion-login-form');
    const closeBtn = document.getElementById('close-notion-modal');
    const prevBtn = document.getElementById('notion-prev-btn');
    const nextBtn = document.getElementById('notion-next-btn');
    const exportBtn = document.getElementById('notion-export-btn');
    const syncBtn = document.getElementById('notion-sync-btn');
    const deleteBtn = document.getElementById('notion-delete-btn');
    const errorEl = document.getElementById('notion-wizard-error');
    const existingContainer = document.getElementById('notion-existing-connections');
    const existingList = document.getElementById('notion-existing-page-list');
    const connectMessage = document.getElementById('notion-connect-message');
    const workspaceNameEl = document.getElementById('notion-workspace-name');
    const parentPageSection = document.getElementById('notion-parent-page-section');
    const parentPageSelect = document.getElementById('notion-parent-page-select');
    const creativeTitleEl = document.getElementById('notion-creative-title');
    const workspaceSummaryEl = document.getElementById('notion-workspace-summary');
    const exportTypeSummaryEl = document.getElementById('notion-export-type-summary');
    const parentSummaryEl = document.getElementById('notion-parent-summary');
    const parentPageSummaryEl = document.getElementById('notion-parent-page-summary');

    // Store original button text for restoration after async operations
    if (exportBtn) exportBtn.dataset.originalText = exportBtn.textContent;
    if (syncBtn) syncBtn.dataset.originalText = syncBtn.textContent;
    if (deleteBtn) deleteBtn.dataset.originalText = deleteBtn.textContent;

    let creativeId = null;
    let currentStep = 'connect';
    let hasExistingIntegration = false;
    let workspaceInfo = null;
    let availablePages = [];
    let exportType = 'new-page';
    let selectedParentPage = null;

    function resetWizard() {
      currentStep = 'connect';
      hasExistingIntegration = false;
      workspaceInfo = null;
      availablePages = [];
      exportType = 'new-page';
      selectedParentPage = null;
      statusEl.textContent = '';
      clearError(errorEl);
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
      if (syncBtn) syncBtn.style.display = 'none';
      if (loginBtn) loginBtn.style.display = 'inline-block';
      if (parentPageSection) parentPageSection.style.display = 'none';
      updateStep();
    }

    function updateStep() {
      updateStepVisibility(currentStep, ['connect', 'workspace', 'summary'], 'notion-step');

      if (currentStep === 'connect') {
        prevBtn.style.display = 'none';
        if (hasExistingIntegration) {
          nextBtn.style.display = 'block';
          nextBtn.disabled = false;
        } else {
          nextBtn.style.display = 'none';
        }
        exportBtn.style.display = 'none';
      } else if (currentStep === 'workspace') {
        prevBtn.style.display = 'block';
        prevBtn.disabled = false;
        nextBtn.style.display = 'block';
        nextBtn.disabled = false;
        exportBtn.style.display = 'none';
      } else if (currentStep === 'summary') {
        prevBtn.style.display = 'block';
        prevBtn.disabled = false;
        nextBtn.style.display = 'none';
        exportBtn.style.display = 'block';
        exportBtn.disabled = false;
      }
    }

    function loadIntegrationStatus() {
      if (!creativeId) return;

      statusEl.textContent = modal.dataset.loading;
      clearError(errorEl);

      fetchWithCsrf(`/notion/creatives/${creativeId}/notion_integration`)
        .then(response => response.json())
        .then(data => {
          console.log('Notion integration status:', data);
          statusEl.textContent = '';
          
          // Store the creative title from the API response
          if (data.creative_title) {
            window.notionCreativeTitle = data.creative_title;
            console.log('Creative title from API:', data.creative_title);
          }
          
          if (data.connected) {
            workspaceInfo = data.account;
            availablePages = data.available_pages || [];
            
            console.log('Available pages:', availablePages);
            
            if (workspaceNameEl) {
              workspaceNameEl.textContent = data.account.workspace_name || modal.dataset.defaultWorkspace;
            }

            if (data.linked_pages && data.linked_pages.length > 0) {
              hasExistingIntegration = true;
              showExistingIntegration(data.linked_pages);
            } else {
              hasExistingIntegration = true;
              if (connectMessage) connectMessage.style.display = 'none';
              if (loginBtn) loginBtn.style.display = 'none';
            }
            
            updateParentPageSelect(); // Update the select with available pages
          } else {
            hasExistingIntegration = false;
            if (connectMessage) connectMessage.textContent = modal.dataset.loginRequired;
          }
          updateStep();
        })
        .catch(error => {
          console.error('Error loading integration status:', error);
          statusEl.textContent = '';
          showError(errorEl, modal.dataset.loadFailed);
        });
    }

    function showExistingIntegration(linkedPages) {
      if (!existingContainer || !existingList) return;

      existingList.innerHTML = '';
      linkedPages.forEach(function (page) {
        const li = document.createElement('li');
        const link = document.createElement('a');
        link.href = page.page_url;
        link.target = '_blank';
        link.textContent = page.page_title || modal.dataset.untitledPage;
        li.appendChild(link);
        
        if (page.last_synced_at) {
          const syncInfo = document.createElement('span');
          syncInfo.textContent = ` (${modal.dataset.syncedLabel} ${new Date(page.last_synced_at).toLocaleDateString()})`;
          syncInfo.style.color = 'var(--color-text-secondary)';
          li.appendChild(syncInfo);
        }
        
        existingList.appendChild(li);
      });

      if (connectMessage) connectMessage.style.display = 'none';
      if (loginBtn) loginBtn.style.display = 'none';
      if (syncBtn) syncBtn.style.display = 'inline-block';
      if (deleteBtn) deleteBtn.style.display = 'inline-block';
      existingContainer.style.display = 'block';
    }

    function loadAvailablePages() {
      // Pages are now loaded with the initial status call
      return Promise.resolve(availablePages);
    }

    function updateParentPageOptions() {
      const showParentSelect = document.querySelector('input[name="notion-export-type"]:checked')?.value === 'select-parent';
      
      if (parentPageSection) {
        parentPageSection.style.display = showParentSelect ? 'block' : 'none';
      }

      if (showParentSelect && availablePages.length === 0) {
        loadAvailablePages().then(pages => {
          availablePages = pages;
          updateParentPageSelect();
        });
      }
    }

    function updateParentPageSelect() {
      if (!parentPageSelect) return;

      console.log('Updating parent page select with', availablePages.length, 'pages');
      parentPageSelect.innerHTML = '';
      
      if (availablePages.length === 0) {
        const option = document.createElement('option');
        option.value = '';
        option.textContent = modal.dataset.noPages;
        parentPageSelect.appendChild(option);
      } else {
        const defaultOption = document.createElement('option');
        defaultOption.value = '';
        defaultOption.textContent = 'Select a parent page';
        parentPageSelect.appendChild(defaultOption);

        availablePages.forEach(page => {
          console.log('Adding page option:', page);
          const option = document.createElement('option');
          option.value = page.id;
          option.textContent = page.title || modal.dataset.untitled;
          parentPageSelect.appendChild(option);
        });
      }
    }

    function updateSummary() {
      if (creativeTitleEl) {
        // Use the creative title from the API response
        const title = window.notionCreativeTitle || modal.dataset.currentCreative;
        console.log(`Creative title used: "${title}" for ID: ${creativeId}`);
        creativeTitleEl.textContent = title;
      }

      if (workspaceSummaryEl && workspaceInfo) {
        workspaceSummaryEl.textContent = workspaceInfo.workspace_name || modal.dataset.defaultWorkspace;
      }

      const selectedExportType = document.querySelector('input[name="notion-export-type"]:checked')?.value || 'new-page';
      exportType = selectedExportType;

      if (exportTypeSummaryEl) {
        exportTypeSummaryEl.textContent = selectedExportType === 'new-page' ? modal.dataset.newPageLabel : modal.dataset.subpageLabel;
      }

      if (selectedExportType === 'select-parent') {
        selectedParentPage = parentPageSelect?.value || null;
        if (parentSummaryEl && parentPageSummaryEl) {
          if (selectedParentPage) {
            const selectedPage = availablePages.find(p => p.id === selectedParentPage);
            parentPageSummaryEl.textContent = selectedPage?.title || modal.dataset.selectedPage;
            parentSummaryEl.style.display = 'block';
          } else {
            parentSummaryEl.style.display = 'none';
          }
        }
      } else {
        if (parentSummaryEl) parentSummaryEl.style.display = 'none';
      }
    }

    function performExport() {
      if (!creativeId) {
        showError(errorEl, modal.dataset.noCreative);
        return;
      }

      exportBtn.disabled = true;
      exportBtn.textContent = modal.dataset.exporting;
      clearError(errorEl);

      const requestData = {
        action: 'export'
      };

      if (exportType === 'select-parent' && selectedParentPage) {
        requestData.parent_page_id = selectedParentPage;
      }

      console.log('Sending export request:', requestData);
      console.log('Export type:', exportType, 'Selected parent page:', selectedParentPage);

      fetchWithCsrf(`/notion/creatives/${creativeId}/notion_integration`, {
        method: 'PATCH',
        body: requestData
      })
        .then(response => response.json())
        .then(data => {
          if (data.success) {
            statusEl.textContent = modal.dataset.exportSuccess || 'Export started successfully';
            statusEl.style.color = 'green';
            setTimeout(() => {
              modal.style.display = 'none';
              resetWizard();
            }, 2000);
          } else {
            showError(errorEl, data.message || modal.dataset.exportFailed);
          }
        })
        .catch(error => {
          console.error('Export error:', error);
          showError(errorEl, modal.dataset.exportFailed);
        })
        .finally(() => {
          exportBtn.disabled = false;
          exportBtn.textContent = exportBtn.dataset.originalText;
        });
    }

    function performSync() {
      if (!creativeId) return;

      syncBtn.disabled = true;
      syncBtn.textContent = modal.dataset.syncing;
      clearError(errorEl);

      fetchWithCsrf(`/notion/creatives/${creativeId}/notion_integration`, {
        method: 'PATCH',
        body: { action: 'sync' }
      })
        .then(response => response.json())
        .then(data => {
          if (data.success) {
            statusEl.textContent = modal.dataset.syncSuccess || 'Sync completed successfully';
            statusEl.style.color = 'green';
          } else {
            showError(errorEl, data.message || modal.dataset.syncFailed);
          }
        })
        .catch(error => {
          console.error('Sync error:', error);
          showError(errorEl, modal.dataset.syncFailed);
        })
        .finally(() => {
          syncBtn.disabled = false;
          syncBtn.textContent = syncBtn.dataset.originalText;
        });
    }

    function performDelete() {
      if (!confirm(modal.dataset.deleteConfirm)) return;

      deleteBtn.disabled = true;
      deleteBtn.textContent = modal.dataset.removing;
      clearError(errorEl);

      fetchWithCsrf(`/notion/creatives/${creativeId}/notion_integration`, { method: 'DELETE' })
        .then(response => response.json())
        .then(data => {
          if (data.success) {
            statusEl.textContent = modal.dataset.deleteSuccess || 'Integration removed successfully';
            statusEl.style.color = 'green';
            setTimeout(() => {
              modal.style.display = 'none';
              resetWizard();
            }, 2000);
          } else {
            showError(errorEl, data.message || modal.dataset.deleteFailed);
          }
        })
        .catch(error => {
          console.error('Delete error:', error);
          showError(errorEl, modal.dataset.deleteFailed);
        })
        .finally(() => {
          deleteBtn.disabled = false;
          deleteBtn.textContent = modal.dataset.deleteButtonLabel;
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

    // Listen for OAuth success message from popup window
    window.addEventListener('message', function(event) {
      // Verify origin for security
      if (event.origin !== window.location.origin) return;
      
      if (event.data && event.data.type === 'notion_oauth_success') {
        console.log('Received Notion OAuth success message');
        loadIntegrationStatus();
      }
    });

    loginBtn.addEventListener('click', function () {
      console.log('Notion login button clicked');
      const authWindow = openOAuthPopup('notion-auth-window', {
        width: parseInt(this.dataset.windowWidth) || 600,
        height: parseInt(this.dataset.windowHeight) || 700,
        onClose: function () {
          console.log('Auth window closed, reloading integration status');
          loadIntegrationStatus();
        }
      });

      if (authWindow) {
        loginForm.target = 'notion-auth-window';
        loginForm.submit();
        console.log('Auth form submitted to popup window');
      } else {
        loginForm.target = '_blank';
        loginForm.submit();
      }
    });

    prevBtn.addEventListener('click', function () {
      if (currentStep === 'workspace') {
        currentStep = 'connect';
      } else if (currentStep === 'summary') {
        currentStep = 'workspace';
      }
      updateStep();
    });

    nextBtn.addEventListener('click', function () {
      clearError(errorEl);
      if (currentStep === 'connect') {
        currentStep = 'workspace';
        updateParentPageOptions();
      } else if (currentStep === 'workspace') {
        updateSummary();
        currentStep = 'summary';
      }
      updateStep();
    });

    exportBtn.addEventListener('click', performExport);
    if (syncBtn) syncBtn.addEventListener('click', performSync);
    if (deleteBtn) deleteBtn.addEventListener('click', performDelete);

    // Listen for export type changes
    document.addEventListener('change', function (e) {
      if (e.target.name === 'notion-export-type') {
        updateParentPageOptions();
      }
    });

    // Listen for parent page selection
    if (parentPageSelect) {
      parentPageSelect.addEventListener('change', function () {
        selectedParentPage = this.value;
      });
    }

  });
}
