import { Controller } from '@hotwired/stimulus'
import csrfFetch from '../lib/api/csrf_fetch'

const WORKSPACE_TREE_DISMISSED_KEY = 'collavre:onboarding:workspace-tree-dismissed'

// A read-only runner: it highlights an anchored UI element but never invokes a
// write. Domain actions advance only after their server-side controller succeeds.
export default class extends Controller {
  static targets = ['instruction', 'step', 'next', 'finish']
  static values = { stateUrl: String, advanceUrl: String, completeUrl: String, currentStep: String }

  connect() {
    this.refreshGeneration = 0
    this.refreshPromise = null
    this.refreshPending = false
    this.refresh = this.refresh.bind(this)
    this.handleWorkspaceTreeClosed = this.handleWorkspaceTreeClosed.bind(this)
    this.workspaceTreeDismissed = this.workspaceTreeWasDismissed()
    document.addEventListener('workspace-tree:panel-closed', this.handleWorkspaceTreeClosed)
    this.refresh()
    this.timer = window.setInterval(this.refresh, 1200)
  }

  disconnect() {
    this.refreshGeneration += 1
    this.refreshPending = false
    if (this.timer) window.clearInterval(this.timer)
    document.removeEventListener('workspace-tree:panel-closed', this.handleWorkspaceTreeClosed)
    document.querySelectorAll('.guide-anchor-highlight').forEach((el) => el.classList.remove('guide-anchor-highlight'))
  }

  async advance() {
    await csrfFetch(this.advanceUrlValue, { method: 'POST' })
    this.refreshGeneration += 1
    this.refresh()
  }

  async complete() {
    const response = await csrfFetch(this.completeUrlValue, { method: 'POST' })
    const data = await response.json()
    if (data.redirect_url) this.navigate(data.redirect_url)
  }

  async refresh() {
    if (this.refreshPromise) {
      this.refreshPending = true
      return this.refreshPromise
    }

    const generation = ++this.refreshGeneration
    this.refreshPromise = this.fetchState(generation)

    try {
      await this.refreshPromise
    } finally {
      this.refreshPromise = null
      const refreshAgain = this.refreshPending
      this.refreshPending = false
      if (refreshAgain) this.refresh()
    }
  }

  async fetchState(generation) {
    const response = await fetch(this.stateUrlValue, { headers: { Accept: 'application/json' } })
    if (generation !== this.refreshGeneration || !response.ok) return
    const state = await response.json()
    if (generation !== this.refreshGeneration) return
    this.render(state)
  }

  render(state) {
    if (state.complete) {
      this.instructionTarget.textContent = state.instruction
      this.nextTarget.hidden = true
      this.finishTarget.hidden = false
      return
    }
    if (!state.current_step) return
    this.currentStepValue = state.current_step
    if (state.navigation_path && this.currentPath() !== state.navigation_path) {
      this.navigate(state.navigation_path)
      return
    }
    this.instructionTarget.textContent = state.instruction
    this.nextTarget.hidden = state.completion !== 'ui'
    this.finishTarget.hidden = true
    this.stepTargets.forEach((step) => {
      step.classList.toggle('is-current', step.dataset.stepKey === state.current_step)
      step.classList.toggle('is-complete', state.completed_steps.includes(step.dataset.stepKey))
    })
    this.highlight(state.anchor, state.anchor_key)
  }

  currentPath() {
    return `${window.location.pathname}${window.location.search}`
  }

  navigate(path) {
    if (window.Turbo) {
      window.Turbo.visit(path)
      return
    }

    window.location.href = path
  }

  highlight(anchor, key) {
    document.querySelectorAll('.guide-anchor-highlight').forEach((el) => el.classList.remove('guide-anchor-highlight'))
    if (anchor === 'tree.node') this.openWorkspaceTree()
    const anchors = anchor ? document.querySelectorAll(`[data-guide-anchor="${anchor}"]`) : []
    const target = key == null
      ? anchors[0]
      : [...anchors].find((element) => element.dataset.guideAnchorKey === String(key)) || anchors[0]
    target?.classList.add('guide-anchor-highlight')
  }

  openWorkspaceTree() {
    const panel = document.querySelector('[data-controller~="workspace-tree"]')
    if (!panel || this.workspaceTreeDismissed) return

    if (panel.classList.contains('is-open')) return

    panel.classList.add('is-open')
    panel.querySelector('[data-workspace-tree-target~="panelToggle"]')?.setAttribute('aria-expanded', 'true')
  }

  handleWorkspaceTreeClosed() {
    this.workspaceTreeDismissed = true
    window.sessionStorage.setItem(WORKSPACE_TREE_DISMISSED_KEY, 'true')
  }

  workspaceTreeWasDismissed() {
    return window.sessionStorage.getItem(WORKSPACE_TREE_DISMISSED_KEY) === 'true'
  }
}
