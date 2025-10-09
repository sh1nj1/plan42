if (!window.notionIntegrationInitialized) {
  window.notionIntegrationInitialized = true;

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

    let creativeId = null;
    let currentStep = 'connect';
    let hasExistingIntegration = false;
    let workspaceInfo = null;
    let availablePages = [];
    let exportType = 'new-page';
    let selectedParentPage = null;

    function csrfToken() {
      return document.querySelector('meta[name="csrf-token"]')?.content;
    }

    function resetWizard() {
      currentStep = 'connect';
      hasExistingIntegration = false;
      workspaceInfo = null;
      availablePages = [];
      exportType = 'new-page';
      selectedParentPage = null;
      statusEl.textContent = '';
      errorEl.style.display = 'none';
      errorEl.textContent = '';
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
      ['connect', 'workspace', 'summary']
        .forEach(function (step) {
          const el = document.getElementById(`notion-step-${step}`);
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

      statusEl.textContent = 'Loading...';
      clearError();

      fetch(`/creatives/${creativeId}/notion_integration`, {
        method: 'GET',
        headers: {
          'X-CSRF-Token': csrfToken(),
          'Content-Type': 'application/json'
        }
      })
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
              workspaceNameEl.textContent = data.account.workspace_name || 'Notion Workspace';
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
          showError('Failed to load integration status');
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
        link.textContent = page.page_title || 'Untitled Page';
        li.appendChild(link);
        
        if (page.last_synced_at) {
          const syncInfo = document.createElement('span');
          syncInfo.textContent = ` (synced ${new Date(page.last_synced_at).toLocaleDateString()})`;
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
        option.textContent = 'No pages available or loading...';
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
          option.textContent = page.title || 'Untitled';
          parentPageSelect.appendChild(option);
        });
      }
    }

    function updateSummary() {
      if (creativeTitleEl) {
        // Use the creative title from the API response
        const title = window.notionCreativeTitle || 'Current Creative';
        console.log(`Creative title used: "${title}" for ID: ${creativeId}`);
        creativeTitleEl.textContent = title;
      }

      if (workspaceSummaryEl && workspaceInfo) {
        workspaceSummaryEl.textContent = workspaceInfo.workspace_name || 'Notion Workspace';
      }

      const selectedExportType = document.querySelector('input[name="notion-export-type"]:checked')?.value || 'new-page';
      exportType = selectedExportType;

      if (exportTypeSummaryEl) {
        exportTypeSummaryEl.textContent = selectedExportType === 'new-page' ? 'New page' : 'Subpage';
      }

      if (selectedExportType === 'select-parent') {
        selectedParentPage = parentPageSelect?.value || null;
        if (parentSummaryEl && parentPageSummaryEl) {
          if (selectedParentPage) {
            const selectedPage = availablePages.find(p => p.id === selectedParentPage);
            parentPageSummaryEl.textContent = selectedPage?.title || 'Selected page';
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
        showError(modal.dataset.noCreative);
        return;
      }

      exportBtn.disabled = true;
      exportBtn.textContent = 'Exporting...';
      clearError();

      const requestData = {
        action: 'export'
      };

      if (exportType === 'select-parent' && selectedParentPage) {
        requestData.parent_page_id = selectedParentPage;
      }

      console.log('Sending export request:', requestData);
      console.log('Export type:', exportType, 'Selected parent page:', selectedParentPage);

      fetch(`/creatives/${creativeId}/notion_integration`, {
        method: 'PATCH',
        headers: {
          'X-CSRF-Token': csrfToken(),
          'Content-Type': 'application/json'
        },
        body: JSON.stringify(requestData)
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
            showError(data.message || 'Export failed');
          }
        })
        .catch(error => {
          console.error('Export error:', error);
          showError('Export failed');
        })
        .finally(() => {
          exportBtn.disabled = false;
          exportBtn.textContent = 'Export to Notion';
        });
    }

    function performSync() {
      if (!creativeId) return;

      syncBtn.disabled = true;
      syncBtn.textContent = 'Syncing...';
      clearError();

      fetch(`/creatives/${creativeId}/notion_integration`, {
        method: 'PATCH',
        headers: {
          'X-CSRF-Token': csrfToken(),
          'Content-Type': 'application/json'
        },
        body: JSON.stringify({ action: 'sync' })
      })
        .then(response => response.json())
        .then(data => {
          if (data.success) {
            statusEl.textContent = modal.dataset.syncSuccess || 'Sync completed successfully';
            statusEl.style.color = 'green';
          } else {
            showError(data.message || 'Sync failed');
          }
        })
        .catch(error => {
          console.error('Sync error:', error);
          showError('Sync failed');
        })
        .finally(() => {
          syncBtn.disabled = false;
          syncBtn.textContent = 'Sync to Notion';
        });
    }

    function performDelete() {
      if (!confirm(modal.dataset.deleteConfirm)) return;

      deleteBtn.disabled = true;
      deleteBtn.textContent = 'Removing...';
      clearError();

      fetch(`/creatives/${creativeId}/notion_integration`, {
        method: 'DELETE',
        headers: {
          'X-CSRF-Token': csrfToken(),
          'Content-Type': 'application/json'
        }
      })
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
            showError(data.message || 'Deletion failed');
          }
        })
        .catch(error => {
          console.error('Delete error:', error);
          showError('Deletion failed');
        })
        .finally(() => {
          deleteBtn.disabled = false;
          deleteBtn.textContent = 'Remove link';
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

    loginBtn.addEventListener('click', function () {
      console.log('Notion login button clicked');
      const width = parseInt(this.dataset.windowWidth) || 600;
      const height = parseInt(this.dataset.windowHeight) || 700;
      const left = (screen.width - width) / 2;
      const top = (screen.height - height) / 2;

      const authWindow = window.open('', 'notion-auth-window', 
        `width=${width},height=${height},left=${left},top=${top},scrollbars=yes,resizable=yes`);
      
      if (authWindow) {
        loginForm.target = 'notion-auth-window';
        loginForm.submit();
        console.log('Auth form submitted to popup window');
        
        const checkClosed = setInterval(() => {
          if (authWindow.closed) {
            clearInterval(checkClosed);
            console.log('Auth window closed, reloading integration status');
            setTimeout(() => loadIntegrationStatus(), 1000);
          }
        }, 1000);
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
      clearError();
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

    modal.addEventListener('click', function (e) {
      if (e.target === modal) {
        modal.style.display = 'none';
        resetWizard();
      }
    });
  });
}
