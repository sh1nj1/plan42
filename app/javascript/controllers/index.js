import { application } from "./application"

// Import and register Collavre engine controllers
import { registerControllers } from "collavre/controllers"
registerControllers(application)

// Host app specific controllers
import AvatarPreviewController from "./avatar_preview_controller"
application.register("avatar-preview", AvatarPreviewController)

import LlmModelController from "./llm_model_controller"
application.register("llm-model", LlmModelController)

import WebauthnController from "./webauthn_controller"
application.register("webauthn", WebauthnController)
