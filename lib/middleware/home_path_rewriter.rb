class HomePathRewriter
  def initialize(app)
    @app = app
  end

  def call(env)
    if env["PATH_INFO"] == "/"
      home_path = SystemSetting.home_page_path.presence
      if home_path
        # Normalize in case value was set via console with invalid format
        normalized = normalize_path(home_path)
        if normalized && normalized != "/"
          env["PATH_INFO"] = normalized
          env["REQUEST_PATH"] = normalized
        end
      end
      # If no custom path configured, "/" stays as "/" (root "creatives#index")
    end
    @app.call(env)
  end

  private

  # Normalize path to guard against out-of-band changes (e.g., via console)
  def normalize_path(path)
    return nil if path.blank?

    # Reject URLs with scheme
    return nil if path.match?(%r{\A[a-z][a-z0-9+.-]*://}i)

    # Strip query string and fragment
    path = path.split(/[?#]/).first

    # Ensure leading slash
    path = "/#{path}" unless path.start_with?("/")

    # Normalize multiple slashes
    path.gsub(%r{/+}, "/")
  end
end
