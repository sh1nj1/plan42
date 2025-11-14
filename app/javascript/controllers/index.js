import { application } from "./application"
import PopupMenuController from "./popup_menu_controller"
import ProgressFilterController from "./progress_filter_controller"
import CreativesImportController from "./creatives/import_controller"
import CreativesSelectModeController from "./creatives/select_mode_controller"
import ActionTextAttachmentLinkController from "./action_text_attachment_link_controller"
import CreativesDragDropController from "./creatives/drag_drop_controller"
import CreativesExpansionController from "./creatives/expansion_controller"
import CreativesRowEditorController from "./creatives/row_editor_controller"
import CreativesTreeController from "./creatives/tree_controller"
import CommentsListController from "./comments/list_controller"
import CommentsFormController from "./comments/form_controller"
import CommentsPresenceController from "./comments/presence_controller"
import CommentsMentionMenuController from "./comments/mention_menu_controller"
import CommentsPopupController from "./comments/popup_controller"
import ClickTargetController from "./click_target_controller"
import CreativesSetPlanModalController from "./creatives/set_plan_modal_controller"

import CommentController from "./comment_controller"
import ShareInviteController from "./share_invite_controller"

application.register("comment", CommentController)
application.register("share-invite", ShareInviteController)
application.register("popup-menu", PopupMenuController)
application.register("progress-filter", ProgressFilterController)
application.register("creatives--import", CreativesImportController)
application.register("creatives--select-mode", CreativesSelectModeController)
application.register("action-text-attachment-link", ActionTextAttachmentLinkController)
application.register("creatives--drag-drop", CreativesDragDropController)
application.register("creatives--expansion", CreativesExpansionController)
application.register("creatives--row-editor", CreativesRowEditorController)
application.register("creatives--tree", CreativesTreeController)
application.register("comments--list", CommentsListController)
application.register("comments--form", CommentsFormController)
application.register("comments--presence", CommentsPresenceController)
application.register("comments--mention-menu", CommentsMentionMenuController)
application.register("comments--popup", CommentsPopupController)
application.register("click-target", ClickTargetController)
application.register("creatives--set-plan-modal", CreativesSetPlanModalController)
