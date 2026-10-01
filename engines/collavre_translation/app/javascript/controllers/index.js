import CreativeTranslationsController from "./creative_translations_controller"
import CommentTranslationController from "./comment_translation_controller"

import CommentTranslationReaderController from "./comment_translation_reader_controller"

export function registerControllers(application) {
  application.register("creative-translations", CreativeTranslationsController)
  application.register("comment-translation-reader", CommentTranslationReaderController)
  application.register("comment-translation", CommentTranslationController)
}
