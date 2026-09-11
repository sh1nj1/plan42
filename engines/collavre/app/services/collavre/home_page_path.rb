# frozen_string_literal: true

module Collavre
  # Resolves the configured authenticated home page into the two shapes the app
  # needs.
  #
  # "/" is reserved for app launch: the middleware flags it and the controller
  # turns it into the last visited Creative. Anything that means "take me to the
  # top level" therefore has to link at the configured home page directly rather
  # than at "/", or it gets swallowed by the launch redirect.
  module HomePagePath
    # Admins can disable the authenticated redirect by setting the path to "/".
    ROOT_SENTINEL = "/"

    module_function

    # Configured path with the engine mount prefix removed, for comparing
    # against engine-relative routes:
    #   "/collavre/creatives" mounted at "/collavre" -> "/creatives"
    def mount_relative(script_name: nil)
      path = configured_path.chomp("/")
      mount = normalized_mount(script_name)
      return path if mount.blank? || !mounted_under?(path, mount)

      path.delete_prefix(mount)
    end

    # Configured path with the engine mount prefix applied, for linking:
    #   "/creatives" mounted at "/collavre" -> "/collavre/creatives"
    #
    # Returns nil when the authenticated home is disabled via the "/" sentinel
    # so callers can fall back to the application root.
    def absolute(script_name: nil)
      path = configured_path
      return nil if path.blank? || path == ROOT_SENTINEL

      mount = normalized_mount(script_name)
      return path if mount.blank? || mounted_under?(path, mount)

      "#{mount}#{path}"
    end

    def configured_path
      SystemSetting.home_page_path_authenticated.to_s.strip
    end

    def normalized_mount(script_name)
      script_name.to_s.chomp("/")
    end

    def mounted_under?(path, mount)
      path == mount || path.start_with?("#{mount}/")
    end
  end
end
