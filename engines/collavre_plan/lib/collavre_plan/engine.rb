module CollavrePlan
  class Engine < ::Rails::Engine
    isolate_namespace CollavrePlan

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

    # Load locale files
    config.i18n.load_path += Dir[root.join("config", "locales", "*.yml")]

    # Auto-mount engine routes at "/" to preserve existing URL paths (/plans, /creative_plan).
    # Unlike slack/notion/github engines which have their own URL namespace, Plan routes
    # don't conflict with core routes and are tightly integrated into the creatives UI.
    initializer "collavre_plan.routes", before: :add_routing_paths do |app|
      app.routes.append do
        mount CollavrePlan::Engine => "/", as: :collavre_plan_engine
      end
    end

    # Add engine stylesheets to asset paths for Propshaft
    initializer "collavre_plan.assets" do |app|
      if app.config.respond_to?(:assets) && app.config.assets.respond_to?(:paths)
        app.config.assets.paths << root.join("app/assets/stylesheets")
      end
    end

    # Register Plan navigation items via Collavre::Navigation::Registry
    initializer "collavre_plan.navigation", after: "collavre.navigation_reset" do
      Rails.application.config.to_prepare do
        next unless defined?(Navigation::Registry)

        # Mobile plans button
        Navigation::Registry.instance.register(
          key: :mobile_plans,
          label: "app.plans",
          type: :partial,
          partial: "collavre_plan/shared/navigation/mobile_plans_button",
          priority: 100,
          requires_auth: true,
          desktop: false,
          mobile: true
        )

        # Desktop plans button
        Navigation::Registry.instance.register(
          key: :plans,
          label: "app.plans",
          type: :partial,
          partial: "collavre_plan/shared/navigation/plans_button",
          priority: 120,
          requires_auth: true,
          mobile: false
        )
      end
    end

    # Register Plan view extensions into core's extension slots
    initializer "collavre_plan.view_extensions", after: "collavre.navigation_reset" do
      Rails.application.config.to_prepare do
        next unless defined?(Collavre::ViewExtensions)

        # Set Plan button in creative toolbar (select mode)
        Collavre::ViewExtensions.register(:creative_toolbar,
          partial: "collavre_plan/creatives/set_plan_button")

        # Set Plan modal in creative modals area
        Collavre::ViewExtensions.register(:creative_modals,
          partial: "collavre/creatives/set_plan_modal")

        # Plans timeline panel in navigation panels
        Collavre::ViewExtensions.register(:navigation_panels,
          partial: "collavre_plan/shared/navigation/panels")
      end
    end
  end
end
