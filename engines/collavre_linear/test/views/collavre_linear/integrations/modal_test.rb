# frozen_string_literal: true

require "test_helper"

module CollavreLinear
  module Integrations
    # Renders the Linear integration modal partial and asserts the correct UI
    # branch is shown for each account/link state.
    class ModalTest < ActionView::TestCase
      tests CollavreLinear::IntegrationsController if defined?(CollavreLinear::IntegrationsController)

      def setup
        @user = Collavre.user_class.create!(
          email: "linear-modal-#{SecureRandom.hex(4)}@example.com",
          name: "Linear Modal",
          password: TEST_PASSWORD,
          password_confirmation: TEST_PASSWORD,
          timezone: "UTC"
        )
        @creative = Collavre::Creative.create!(
          description: "<p>Modal creative</p>",
          user: @user
        )
        Current.user = @user
      end

      def teardown
        Current.reset
      end

      def render_modal(connected:)
        render(
          partial: "collavre_linear/integrations/modal",
          locals: { creative: @creative, connected: connected }
        )
      end

      test "shows the connect (OAuth) button when the user has no Linear account" do
        html = render_modal(connected: false)

        assert_includes html, I18n.t("collavre_linear.integration.connect_button")
        assert_includes html, "/linear/auth/store_creative"
        assert_includes html, %(data-creative-id="#{@creative.id}")
      end

      test "shows the team/project link form for an admin who is connected but not linked" do
        html = render_modal(connected: true)

        assert_includes html, I18n.t("collavre_linear.integration.link_button")
        assert_includes html, I18n.t("collavre_linear.integration.team_id_label")
        assert_includes html, I18n.t("collavre_linear.integration.project_id_label")
      end

      test "link form renders dropdowns (not text inputs) wired to the options endpoint" do
        html = render_modal(connected: true)

        # Combo boxes so the user picks by name instead of typing raw IDs.
        assert_match %r{<select[^>]*name="linear_project_id"}, html
        assert_match %r{<select[^>]*name="team_id"}, html
        refute_match %r{<input[^>]*name="linear_project_id"[^>]*type="text"}, html
        # JS fetches teams/projects from the per-creative options endpoint.
        assert_includes html, "/linear/creatives/#{@creative.id}/integration/options"
        assert_includes html, I18n.t("collavre_linear.integration.project_select_placeholder")
      end

      test "shows resync + unlink actions when a project link already exists" do
        account = CollavreLinear::Account.create!(
          user: @user,
          linear_uid: "uid-modal-#{SecureRandom.hex(4)}",
          access_token: "tok-modal"
        )
        CollavreLinear::ProjectLink.create!(
          creative: @creative.effective_origin,
          account: account,
          linear_project_id: "proj-modal-1",
          team_id: "team-modal-1",
          webhook_secret: "modal-secret"
        )

        html = render_modal(connected: true)

        assert_includes html, I18n.t("collavre_linear.integration.unlink_button")
        assert_includes html, I18n.t("collavre_linear.integration.resync_button")
        assert_includes html, "proj-modal-1"
      end

      test "shows the manual webhook guide with a paste field (not the secret) when unset" do
        account = CollavreLinear::Account.create!(
          user: @user,
          linear_uid: "uid-guide-#{SecureRandom.hex(4)}",
          access_token: "tok-guide"
        )
        # No secret yet → guide must show the /linear/webhook URL and a field to
        # paste Linear's generated secret into (posting to the secret endpoint).
        link = CollavreLinear::ProjectLink.create!(
          creative: @creative.effective_origin,
          account: account,
          linear_project_id: "proj-guide-1",
          team_id: "team-guide-1"
        )

        html = render_modal(connected: true)

        assert_includes html, I18n.t("collavre_linear.integration.webhook_guide_title")
        assert_includes html, "/linear/webhook"
        assert_includes html, "/linear/creatives/#{@creative.id}/integration/secret"
        assert_match %r{<input[^>]*name="webhook_secret"}, html
        assert_includes html, I18n.t("collavre_linear.integration.webhook_secret_unset")
        # Sanity: nothing to leak because Linear owns the secret and none is set.
        assert_nil link.webhook_secret
      end

      test "shows saved status and never renders the stored secret once pasted" do
        account = CollavreLinear::Account.create!(
          user: @user,
          linear_uid: "uid-saved-#{SecureRandom.hex(4)}",
          access_token: "tok-saved"
        )
        CollavreLinear::ProjectLink.create!(
          creative: @creative.effective_origin,
          account: account,
          linear_project_id: "proj-saved-1",
          team_id: "team-saved-1",
          webhook_secret: "super-secret-value"
        )

        html = render_modal(connected: true)

        assert_includes html, I18n.t("collavre_linear.integration.webhook_secret_saved")
        # The signing secret is Linear's to display, never ours — must not echo back.
        refute_includes html, "super-secret-value"
      end

      test "webhook guide uses defined design tokens so text is visible in dark mode" do
        account = CollavreLinear::Account.create!(
          user: @user,
          linear_uid: "uid-tok-#{SecureRandom.hex(4)}",
          access_token: "tok-tok"
        )
        CollavreLinear::ProjectLink.create!(
          creative: @creative.effective_origin,
          account: account,
          linear_project_id: "proj-tok-1",
          team_id: "team-tok-1"
        )

        html = render_modal(connected: true)

        # These token names are NOT defined in design_tokens.css, so their
        # hardcoded light fallbacks (#f8f8f8 / #666) would force a near-white
        # box + inherited near-white text in dark mode → invisible.
        refute_includes html, "--color-surface-secondary"
        refute_includes html, "--color-text-secondary"
        # Real tokens that carry dark-mode overrides.
        assert_includes html, "var(--surface-secondary)"
        assert_includes html, "var(--text-muted)"
      end
    end
  end
end
