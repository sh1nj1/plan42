# automatically configure all engines in the 'engines/' directory
Rails.application.config.to_prepare do
  engines_root = Rails.root.join("engines")

  Rails::Engine.subclasses.each do |engine|
    if engine.root.to_s.start_with?(engines_root.to_s)
      # 1. View Overrides: Prepend views
      ActionController::Base.prepend_view_path(engine.root.join("app/views"))
    end
  end
end


# Register migrations & Locales & Static files automatically (runs on boot)
engines_root = Rails.root.join("engines")
Dir.glob("#{engines_root}/*").each do |engine_path|
  if File.directory?(engine_path)
    # 1. Migrations
    migrations_path = "#{engine_path}/db/migrate"
    if File.exist?(migrations_path)
      Rails.application.config.paths["db/migrate"] << migrations_path
    end

    # 2. I18n (Locales)
    # We append engine locales to the load_path so they are loaded LAST.
    # This allows the Engine to override the Host App's translations.
    Rails.application.config.i18n.load_path += Dir["#{engine_path}/config/locales/**/*.{rb,yml}"]

    # 3. Static Assets (public/)
    # Insert middleware to serve engine's public/ directory
    # BEFORE the main app's static file server.
    public_path = "#{engine_path}/public"
    if File.directory?(public_path)
      Rails.application.config.middleware.insert_before(
        ActionDispatch::Static,
        ActionDispatch::Static,
        public_path
      )
    end
  end
end
