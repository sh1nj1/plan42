# Be sure to restart your server when you modify this file.

# Define an application-wide content security policy.
# See the Securing Rails Applications Guide for more information:
# https://guides.rubyonrails.org/security.html#content-security-policy-header

Rails.application.configure do
  config.content_security_policy do |policy|
    policy.default_src :self
    policy.font_src    :self, :data, "https://fonts.gstatic.com"
    policy.img_src     :self, :data, :blob, "https:"
    policy.object_src  :none
    policy.script_src  :self, :unsafe_eval, :blob
    # Note: unsafe_inline required for inline style="..." attributes in views
    # TODO: Migrate inline styles to CSS classes, then remove unsafe_inline
    policy.style_src   :self, :unsafe_inline, "https://fonts.googleapis.com"
    policy.frame_src   :self, "https://www.youtube.com", "https://www.youtube-nocookie.com"
    policy.media_src   :self, :blob
    policy.worker_src  :self, :blob
    policy.child_src   :self, :blob

    # ActionCable WebSocket origins. Production serves over https, so cable uses
    # wss on the default port (matched by the scheme-wide "wss:"). The desktop app
    # is served over plain http on a loopback port: the Tauri webview opens
    # http://127.0.0.1:<PORT> and ActionCable connects to ws://127.0.0.1:<PORT>/cable.
    # CSP matches host AND port literally, so an unported "ws://localhost" matches
    # neither 127.0.0.1 nor the dynamic port — enforcing CSP would silently kill the
    # realtime UI. Allow the actual webview origin (and, in open mode, the externally
    # reachable DEFAULT_URL_HOST) including its port.
    cable_ws = []
    unless Rails.env.production?
      port  = ENV["PORT"]
      hosts = [ "127.0.0.1", ENV["DEFAULT_URL_HOST"] ].compact.uniq
      hosts.each do |h|
        origin = port ? "#{h}:#{port}" : h
        cable_ws << "ws://#{origin}" << "wss://#{origin}"
      end
      # Safety net: if the port is unknown at boot (non-launcher run), fall back to
      # scheme-wide ws so the loopback cable is never silently blocked.
      cable_ws << "ws:" if port.nil?
    end
    policy.connect_src :self, :blob, "wss:", "https:", *cable_ws

    # Specify URI for violation reports (optional - enable if you want to collect CSP violations)
    # policy.report_uri "/csp-violation-report-endpoint"
  end

  # Nonces disabled: unsafe_inline is used for style-src due to inline style attributes
  # TODO: When inline styles are migrated to CSS classes, enable nonces:
  # config.content_security_policy_nonce_generator = ->(request) { SecureRandom.base64(16) }
  # config.content_security_policy_nonce_directives = %w[style-src]

  # Report-only in dev/test; enforce in deployed builds. The desktop app inherits
  # production hardening (production.rb) and ships as a packaged binary, so its
  # rendered content must be CSP-enforced, not merely reported. RAILS_ENV=desktop
  # is not production?, so it must be named explicitly.
  config.content_security_policy_report_only = !(Rails.env.production? || Rails.env.desktop?)
end
