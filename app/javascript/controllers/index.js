import { application } from "./application"

import CommentController from "./comment_controller"
import ShareInviteController from "./share_invite_controller"

application.register("comment", CommentController)
application.register("share-invite", ShareInviteController)
