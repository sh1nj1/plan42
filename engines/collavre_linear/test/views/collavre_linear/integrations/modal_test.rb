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
          webhook_id: "wh-modal-1"
        )

        html = render_modal(connected: true)

        assert_includes html, I18n.t("collavre_linear.integration.unlink_button")
        assert_includes html, I18n.t("collavre_linear.integration.resync_button")
        assert_includes html, "proj-modal-1"
        # Webhook is present, so the manual setup guide must NOT be shown.
        refute_includes html, I18n.t("collavre_linear.integration.webhook_guide_title")
      end

      test "shows the manual webhook setup guide (url + secret) when linked without a webhook" do
        account = CollavreLinear::Account.create!(
          user: @user,
          linear_uid: "uid-guide-#{SecureRandom.hex(4)}",
          access_token: "tok-guide"
        )
        # webhook_id blank → inbound not wired → guide must appear with the
        # /linear/webhook URL and this link's signing secret.
        link = CollavreLinear::ProjectLink.create!(
          creative: @creative.effective_origin,
          account: account,
          linear_project_id: "proj-guide-1",
          team_id: "team-guide-1"
        )

        html = render_modal(connected: true)

        assert_includes html, I18n.t("collavre_linear.integration.webhook_guide_title")
        assert_includes html, "/linear/webhook"
        assert_includes html, link.webhook_secret
      end
    end
  end
end
