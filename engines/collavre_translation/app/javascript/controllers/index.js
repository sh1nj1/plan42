import CreativeTranslationsController from "./creative_translations_controller"
import CommentTranslationController from "./comment_translation_controller"

export function registerControllers(application) {
  application.register("creative-translations", CreativeTranslationsController)
  application.register("comment-translation", CommentTranslationController)
}
