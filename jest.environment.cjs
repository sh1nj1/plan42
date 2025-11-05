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
  }

  async teardown() {
    if (this.dom) {
      this.dom.window.close()
    }
    await super.teardown()
  }
}

module.exports = CustomJsdomEnvironment
