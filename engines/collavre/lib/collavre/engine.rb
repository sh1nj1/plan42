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

    # Register engine-internal integration settings keys with the central
    # registry. These keys are consumed by engine code (mailer `from`, public
    # assets helper, MCP upload service), so the engine itself must own their
    # registration — host apps may not include the app-level
    # `integration_settings_app.rb` initializer when mounting the engine as a gem.
    # `register` is idempotent, so host app re-registration remains safe.
    initializer "collavre.integration_settings_registry", before: :load_config_initializers do
      if defined?(Collavre::IntegrationSettings::Registry)
        registry = Collavre::IntegrationSettings::Registry.instance
        registry.register(:default_mailer_from, category: "mail", sensitive: false, requires_restart: true)
        registry.register(:public_assets_host,  category: "mail", sensitive: false, requires_restart: false)
        # LLM keys consumed by Collavre::AiClient (engine service). Owned by the
        # engine so gem-mounted host apps don't depend on the app-level
        # `ruby_llm.rb` initializer for ENV fallback.
        registry.register(:gemini_api_key,    category: "llm", sensitive: true,  requires_restart: true)
        registry.register(:openai_api_key,    category: "llm", sensitive: true,  requires_restart: false)
        registry.register(:anthropic_api_key, category: "llm", sensitive: true,  requires_restart: false)
        registry.register(:gemini_api_base,   category: "llm", sensitive: false, requires_restart: true)
      end
    end

    # AWS keys are consumed by `config/environments/*.rb` (active_storage.service
    # decision, SMTP scaffold) and `config/storage.yml` ERB, both of which evaluate
    # during the `:load_environment_config` initializer — earlier than
    # `:load_config_initializers`. Register them in their own block so
    # `IntegrationSettings.fetch` can resolve the keys at that earlier point.
    # S3 keys are `requires_restart: true` because Rails resolves the storage
    # service once at boot; SES keys are runtime-injected by SesSettingsInterceptor.
    initializer "collavre.integration_settings_registry.aws", before: :load_environment_config do
      if defined?(Collavre::IntegrationSettings::Registry)
        registry = Collavre::IntegrationSettings::Registry.instance
        registry.register(:aws_s3_access_key_id,     category: "aws_s3",  sensitive: true,  requires_restart: true)
        registry.register(:aws_s3_secret_access_key, category: "aws_s3",  sensitive: true,  requires_restart: true)
        registry.register(:aws_s3_bucket,            category: "aws_s3",  sensitive: false, requires_restart: true)
        registry.register(:aws_region,               category: "aws_s3",  sensitive: false, requires_restart: true)
        registry.register(:aws_ses_smtp_username,    category: "aws_ses", sensitive: true,  requires_restart: false)
        registry.register(:aws_ses_smtp_password,    category: "aws_ses", sensitive: true,  requires_restart: false)
      end
    end

    # Register the SES SMTP settings interceptor so each outgoing mail picks up
    # the current DB > ENV > credentials value for SES creds at send time.
    # Hooked after ActionMailer loads to ensure Mail::SMTP is defined.
    initializer "collavre.ses_settings_interceptor" do
      ActiveSupport.on_load(:action_mailer) do
        require "mail"
        ::Mail.register_interceptor(Collavre::SesSettingsInterceptor)
      end
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

    # Boot the self-scheduling CronSchedulerJob for dynamic recurring tasks.
    # Uses DB-based guard (SolidQueue::Job table) to prevent duplicate chains.
    # Boot the self-scheduling CronSchedulerJob for dynamic recurring tasks.
    # Uses DB-based guard (SolidQueue::Job table) to prevent duplicate chains.
    # Runs in any non-test process that has DB access — the DB guard ensures
    # only one scheduler chain is active regardless of how many processes boot.
    initializer "collavre.cron_scheduler" do
      config.after_initialize do
        next if Rails.env.test?

        # DB-based check: skip if a CronSchedulerJob is already pending
        pending = SolidQueue::Job.where(class_name: "Collavre::CronSchedulerJob", finished_at: nil)
        failed_ids = SolidQueue::FailedExecution.pluck(:job_id)
        pending = pending.where.not(id: failed_ids) if failed_ids.any?
        unless pending.exists?
          Rails.logger.info("[CronScheduler] Booting self-scheduling cron scheduler")
          Collavre::CronSchedulerJob.perform_later
        else
          Rails.logger.info("[CronScheduler] Already running, skipping boot")
        end
      rescue StandardError => e
        Rails.logger.error("[CronScheduler] Failed to boot: #{e.message}")
      end
    end

    # Reset navigation registry before any registrations (runs first)
    initializer "collavre.navigation_reset" do
      ActiveSupport::Reloader.to_prepare(prepend: true) do
        Navigation::Registry.instance.reset!
        Collavre::ViewExtensions.reset!
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
          section: :main,
          type: :partial,
          partial: "collavre/shared/navigation/search_form",
          priority: 105,
          requires_auth: true
        )

        # ============================================
        # Main Section - Mobile Only
        # ============================================
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

        # Progress filter moved into search popup (search_form partial)

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
          label: "app.help",
          type: :partial,
          partial: "collavre/shared/navigation/help_button",
          priority: 170,
          mobile: true
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
              priority: 100
            },
            {
              key: :sign_out,
              label: "app.sign_out",
              type: :button,
              path: -> { Collavre::Engine.routes.url_helpers.session_path },
              method: :delete,
              priority: 900
            },
            {
              key: :help_menu,
              label: "app.help",
              type: :partial,
              partial: "collavre/shared/navigation/help_button",
              priority: 950
            }
          ]
        )
      end
    end
  end
end
