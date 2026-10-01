import CommentTranslationController from "./comment_translation_controller"

export function registerControllers(application) {
  application.register("comment-translation", CommentTranslationController)
}
