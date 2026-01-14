# lib/local_engine_setup.rb
class LocalEngineSetup
  def self.run(app)
    engines_root = Rails.root.join("engines")
    return unless File.directory?(engines_root)

    # 1. View Overrides: Prepend view paths for all Engines found
    # We look for Rails::Engine subclasses rooted in ./engines/
    Rails::Engine.subclasses.each do |engine|
      if engine.root.to_s.start_with?(engines_root.to_s)
        ActionController::Base.prepend_view_path(engine.root.join("app/views"))
      end
    end

    # 2. Iterate directories for things that don't strictly require a loaded Engine class
    # (Though typically they go together)
    Dir.glob("#{engines_root}/*").each do |engine_path|
      next unless File.directory?(engine_path)

      # A. Migrations
      migrations_path = "#{engine_path}/db/migrate"
      if File.exist?(migrations_path)
        app.config.paths["db/migrate"] << migrations_path
      end

      # B. I18n (Locales)
      # Append to load_path to ensure overrides (loaded last wins usually, but dependent on load order)
      # For I18n, Rails loads files. The order in load_path matters.
      # Users might want to strictly prepend to ensure precedence?
      # Actually Rails I18n: last definition wins for same key.
      # So appending is usually correct if we want to add *more* or *override*.
      app.config.i18n.load_path += Dir["#{engine_path}/config/locales/**/*.{rb,yml}"]

      # C. Static Assets (public/)
      public_path = "#{engine_path}/public"
      if File.directory?(public_path)
        app.config.middleware.insert_before(
          ActionDispatch::Static,
          ActionDispatch::Static,
          public_path
        )
      end
    end
  end
end
