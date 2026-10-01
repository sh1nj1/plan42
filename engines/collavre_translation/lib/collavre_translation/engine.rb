module CollavreTranslation
  class Engine < ::Rails::Engine
    isolate_namespace CollavreTranslation

    initializer "collavre_translation.settings" do
      registry = Collavre::IntegrationSettings::Registry.instance
      registry.register(:translation_llm_vendor, category: "translation", sensitive: false, default: "google")
      registry.register(:translation_llm_model, category: "translation", sensitive: false)
    end

    initializer "collavre_translation.routes", before: :add_routing_paths do |app|
      app.routes.append do
        mount CollavreTranslation::Engine => "/translation", as: :collavre_translation
      end
    end

    initializer "collavre_translation.migrations" do |app|
      config.paths["db/migrate"].expanded.each { |path| app.config.paths["db/migrate"] << path }
    end

    initializer "collavre_translation.extensions", after: "collavre.navigation_reset" do
      config.to_prepare do
        Collavre::ViewExtensions.register(:comment_content_extensions,
          partial: "collavre_translation/comments/translation")
        Collavre::Comment.has_many :translations, class_name: "CollavreTranslation::Translation",
          as: :translatable, dependent: :destroy
      end
    end
  end
end
