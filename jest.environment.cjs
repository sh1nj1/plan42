const NodeEnvironmentModule = require("jest-environment-node")
const NodeEnvironment = NodeEnvironmentModule.default || NodeEnvironmentModule

class CustomJsdomEnvironment extends NodeEnvironment {
  async setup() {
    await super.setup()
    const {JSDOM} = await import("jsdom")
    this.dom = new JSDOM("", {url: "http://localhost"})
    const {window} = this.dom
    this.global.window = window
    this.global.document = window.document
    this.global.DOMParser = window.DOMParser
    this.global.Node = window.Node
    this.global.Element = window.Element
    // Lexical reads several browser globals — `navigator` at module-eval time
    // (navigator.platform for IS_APPLE), the rest at runtime. Node 21+ exposes
    // `navigator` as a getter-only global, so a plain assignment can throw in
    // strict mode; defineProperty replaces the read-only accessor with jsdom's.
    Object.defineProperty(this.global, "navigator", {
      value: window.navigator,
      configurable: true,
      writable: true,
    })
    this.global.getComputedStyle = window.getComputedStyle
    this.global.MutationObserver = window.MutationObserver
    this.global.Text = window.Text
    this.global.HTMLElement = window.HTMLElement
  }

  async teardown() {
    if (this.dom) {
      this.dom.window.close()
    }
    await super.teardown()
  }
}

module.exports = CustomJsdomEnvironment
