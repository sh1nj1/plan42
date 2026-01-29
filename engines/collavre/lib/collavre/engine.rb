module Collavre
  class Engine < ::Rails::Engine
    isolate_namespace Collavre

    config.generators do |g|
      g.test_framework :minitest
    end

    # Path to engine's JavaScript sources for jsbundling-rails integration
    def self.javascript_path
      root.join("app/javascript")
    end

    # Path to engine's stylesheet sources
    def self.stylesheet_path
      root.join("app/assets/stylesheets")
    end

    # Add engine migrations to main app's migration path
    # This allows migrations to live in the engine but be run from the host app
    initializer "collavre.migrations" do |app|
      unless app.root.to_s.match?(root.to_s)
        config.paths["db/migrate"].expanded.each do |expanded_path|
          app.config.paths["db/migrate"] << expanded_path
        end
      end
    end

    initializer "collavre.assets" do |app|
      app.config.assets.precompile += %w[collavre.js] if app.config.respond_to?(:assets)

      # Add engine stylesheets to asset paths for Propshaft
      if app.config.respond_to?(:assets) && app.config.assets.respond_to?(:paths)
        app.config.assets.paths << root.join("app/assets/stylesheets")
      end
    end

    initializer "collavre.importmap", before: "importmap" do |app|
      if app.config.respond_to?(:importmap)
        app.config.importmap.paths << Engine.root.join("config/importmap.rb")
      end
    end

    # Allow engine controllers to fall back to host app views during migration
    # This enables gradual view migration - views can stay in host app until moved to engine
    initializer "collavre.view_paths" do
      ActiveSupport.on_load(:action_controller) do
        append_view_path Rails.root.join("app/views")
      end
    end

    # Make engine URL helpers available to controllers and views via the `collavre` method
    # This avoids conflicts with main app routes while still providing access to engine routes
    initializer "collavre.url_helpers" do
      ActiveSupport.on_load(:action_controller_base) do
        # Add to controllers
        define_method :collavre do
          Collavre::Engine.routes.url_helpers
        end
        private :collavre

        # Add to views via helper
        helper do
          def collavre
            Collavre::Engine.routes.url_helpers
          end
        end
      end
    end

    # Reset navigation registry before any registrations (runs first)
    initializer "collavre.navigation_reset" do
      ActiveSupport::Reloader.to_prepare(prepend: true) do
        Navigation::Registry.instance.reset!
      end
    end

    # Register core navigation items
    # Host app or other engines can add/modify items in their own initializers
    initializer "collavre.navigation", after: "collavre.navigation_reset" do
      Rails.application.config.to_prepare do
        # ============================================
        # Search Section
        # ============================================
        Navigation::Registry.instance.register(
          key: :search,
          label: "app.search_placeholder",
          section: :search,
          type: :partial,
          partial: "collavre/shared/navigation/search_form",
          priority: 10
        )

        # ============================================
        # Main Section - Mobile Only
        # ============================================
        Navigation::Registry.instance.register(
          key: :mobile_plans,
          label: "app.plans",
          type: :partial,
          partial: "collavre/shared/navigation/mobile_plans_button",
          priority: 100,
          requires_auth: true,
          desktop: false,
          mobile: true
        )

        # ============================================
        # Main Section - Desktop Navigation
        # ============================================
        Navigation::Registry.instance.register(
          key: :home,
          label: "app.home",
          type: :button,
          path: -> { main_app.root_path },
          priority: 110
        )

        Navigation::Registry.instance.register(
          key: :plans,
          label: "app.plans",
          type: :partial,
          partial: "collavre/shared/navigation/plans_button",
          priority: 120,
          requires_auth: true,
          mobile: false
        )

        Navigation::Registry.instance.register(
          key: :progress_filter,
          label: "",
          type: :component,
          component: Collavre::ProgressFilterComponent,
          component_args: {
            current_state: -> {
              if params[:min_progress] == "1" && params[:max_progress] == "1"
                :complete
              elsif params[:min_progress] == "0" && params[:max_progress] == "0.99"
                :incomplete
              else
                :all
              end
            },
            states: [
              { name: -> { I18n.t("app.filter_complete") }, value: :complete },
              { name: -> { I18n.t("app.filter_incomplete") }, value: :incomplete },
              { name: -> { I18n.t("app.filter_all") }, value: :all }
            ]
          },
          priority: 130,
          requires_auth: true
        )

        Navigation::Registry.instance.register(
          key: :comment_filter,
          label: "",
          type: :component,
          component: Collavre::ProgressFilterComponent,
          component_args: {
            current_state: -> { params[:comment] == "true" ? :comment : nil },
            states: [
              { name: -> { I18n.t("app.filter_comments") }, value: :comment }
            ]
          },
          priority: 140,
          requires_auth: true
        )

        Navigation::Registry.instance.register(
          key: :inbox,
          label: "app.inbox",
          type: :partial,
          partial: "collavre/shared/navigation/inbox_button",
          priority: 150,
          requires_user: true,
          mobile: false
        )

        Navigation::Registry.instance.register(
          key: :mobile_inbox,
          label: "app.inbox",
          type: :partial,
          partial: "collavre/shared/navigation/mobile_inbox_button",
          priority: 155,
          requires_user: true,
          desktop: false,
          mobile: true
        )

        Navigation::Registry.instance.register(
          key: :sign_in,
          label: "app.sign_in",
          type: :button,
          path: -> { Collavre::Engine.routes.url_helpers.new_session_path },
          priority: 160,
          visible: -> { !authenticated? }
        )

        Navigation::Registry.instance.register(
          key: :help,
          label: "?",
          type: :partial,
          partial: "collavre/shared/navigation/help_button",
          priority: 170
        )

        # ============================================
        # User Section
        # ============================================
        Navigation::Registry.instance.register(
          key: :user_menu,
          label: "",
          section: :user,
          type: :raw,
          button_content: -> { render(AvatarComponent.new(user: Current.user, size: 32, classes: "nav-avatar avatar")) },
          menu_id: "user-menu",
          align: :right,
          priority: 100,
          requires_user: true,
          children: [
            {
              key: :profile,
              label: "collavre.users.profile",
              type: :button,
              path: -> { Collavre::Engine.routes.url_helpers.user_path(Current.user) },
              html_class: "popup-menu-item",
              priority: 100
            },
            {
              key: :sign_out,
              label: "app.sign_out",
              type: :button,
              path: -> { Collavre::Engine.routes.url_helpers.session_path },
              method: :delete,
              priority: 900
            }
          ]
        )
      end
    end
  end
end
