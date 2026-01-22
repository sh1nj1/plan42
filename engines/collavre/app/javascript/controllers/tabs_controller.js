import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = [ "panel", "tabButton" ]
  static values = { activeTab: String }

  connect() {
    if (!this.hasActiveTabValue) {
      this.activeTabValue = "profile"
    }
    this.showActive()
  }

  switch(event) {
    event.preventDefault()
    const tab = event.params?.tab || event.currentTarget.dataset.tabsTabParam
    if (!tab) return

    this.activeTabValue = tab
    this.showActive()
    this.updateUrl(tab)
  }

  showActive() {
    this.panelTargets.forEach((panel) => {
      panel.classList.toggle("active", panel.dataset.tabName === this.activeTabValue)
    })

    this.tabButtonTargets.forEach((button) => {
      button.classList.toggle("active", button.dataset.tabsTabParam === this.activeTabValue)
    })
  }

  updateUrl(tab) {
    if (typeof window === "undefined") return
    const url = new URL(window.location)
    url.searchParams.set("tab", tab)
    if (tab !== "contacts") {
      url.searchParams.delete("contact_page")
    }
    window.history.replaceState({}, "", url)
  }
}
