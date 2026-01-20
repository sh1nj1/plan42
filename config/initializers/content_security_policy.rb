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
    policy.connect_src :self, :blob, "wss:", "https:"
    policy.media_src   :self, :blob
    policy.worker_src  :self, :blob
    policy.child_src   :self, :blob

    # For ActionCable WebSocket connections
    policy.connect_src :self, :blob, "wss://#{ENV.fetch('DEFAULT_URL_HOST', 'localhost')}", "https:"

    # Specify URI for violation reports (optional - enable if you want to collect CSP violations)
    # policy.report_uri "/csp-violation-report-endpoint"
  end

  # Nonces disabled: unsafe_inline is used for style-src due to inline style attributes
  # TODO: When inline styles are migrated to CSS classes, enable nonces:
  # config.content_security_policy_nonce_generator = ->(request) { SecureRandom.base64(16) }
  # config.content_security_policy_nonce_directives = %w[style-src]

  # Report violations without enforcing the policy (set to true for initial deployment)
  # Once verified, set to false to enforce the policy
  config.content_security_policy_report_only = Rails.env.production? ? false : true
end
