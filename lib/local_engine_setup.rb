require "set"

class LocalEngineSetup
  @configured_roots = Set.new

  def self.reset!
    @configured_roots.clear
  end

  def self.run(app, root: nil, view_paths_only: false)
    engines_root = root || Rails.root.join("engines")
    return unless File.directory?(engines_root)

    # 1. View Overrides: Prepend view paths for all Engines found
    # We look for Rails::Engine subclasses rooted in ./engines/
    Rails::Engine.subclasses.each do |engine|
      if engine.root.to_s.start_with?(engines_root.to_s)
        view_path = engine.root.join("app/views").to_s
        # Ensure uniqueness and precedence:
        # Remove the path if it already exists (e.g. from Rails auto-load or previous run)
        # so that prepend_view_path moves it to the TOP.
        if ActionController::Base.view_paths.any? { |p| p.to_s == view_path }
          ActionController::Base.view_paths = ActionController::Base.view_paths.reject { |p| p.to_s == view_path }
        end
        ActionController::Base.prepend_view_path(view_path)
      end
    end

    # Return early if we only wanted to update view paths, or if this root was already configured
    # (checking @configured_roots avoids duplicate migrations/middleware on re-runs)
    return if view_paths_only || @configured_roots.include?(engines_root.to_s)
    @configured_roots << engines_root.to_s

    # 2. Iterate directories for things that don't strictly require a loaded Engine class
    Dir.glob("#{engines_root}/*").each do |engine_path|
      next unless File.directory?(engine_path)

      # A. Migrations
      migrations_path = "#{engine_path}/db/migrate"
      if File.exist?(migrations_path) && !app.config.paths["db/migrate"].include?(migrations_path)
        app.config.paths["db/migrate"] << migrations_path
      end

      # B. I18n (Locales)
      # Use set union |= to avoid duplicates
      app.config.i18n.load_path |= Dir["#{engine_path}/config/locales/**/*.{rb,yml}"]

      # C. Static Assets (public/)
      public_path = "#{engine_path}/public"
      if File.directory?(public_path)
        if app.config.public_file_server.enabled
            # Check if we already inserted this path
            already_added = app.middleware.any? do |m|
              m.klass == ActionDispatch::Static &&
              (m.args.first.to_s == public_path.to_s ||
               m.inspect.include?(public_path.to_s))
            end

            unless already_added
              begin
                index = app.config.public_file_server.index_name
                headers = app.config.public_file_server.headers || {}

                app.config.middleware.insert_before(
                  ActionDispatch::Static,
                  ActionDispatch::Static,
                  public_path,
                  index: index,
                  headers: headers
                )
              rescue FrozenError
                # Cannot modify middleware stack after initialization (e.g. in tests)
              rescue RuntimeError
                # ActionDispatch::Static not found in stack, cannot insert before it.
              end
            end
        end
      end
    end
  end
end
