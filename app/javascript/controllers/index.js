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

import AssignmentRowController from "./assignment_row_controller"
application.register("assignment-row", AssignmentRowController)

import OrganizationEditController from "./organization_edit_controller"
application.register("organization-edit", OrganizationEditController)

import H3StatusFilterController from "./h3_status_filter_controller"
application.register("h3-status-filter", H3StatusFilterController)
