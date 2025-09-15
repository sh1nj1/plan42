import { application } from "./application"

// Eager load all controllers within this directory and register them
const controllers = import.meta.glob("./**/*_controller.js", { eager: true })
for (const path in controllers) {
  const identifier = path
    .replace("./", "")
    .replace(/_controller\.js$/, "")
    .replace(/\//g, "--")
    .replace(/_/g, "-")
  application.register(identifier, controllers[path].default)
}
