require "test_helper"

module Collavre
  class LandingControllerTest < ActionDispatch::IntegrationTest
    DEMO_ID = Collavre::LandingController::LANDING_DEMO_CREATIVE_ID

    setup do
      @owner = User.create!(email: "landing_owner@example.com", password: TEST_PASSWORD,
                            name: "Landing Owner", email_verified_at: Time.current)
      @creative = Collavre::Creative.create!(id: DEMO_ID, description: "<p>assets</p>", user: @owner)
    end

    def attach(filename, content_type: "video/mp4", created_at: nil)
      blob = ActiveStorage::Blob.create_and_upload!(
        io: StringIO.new("bytes-#{filename}-#{created_at&.to_i}"),
        filename: filename, content_type: content_type
      )
      blob.update_column(:created_at, created_at) if created_at
      @creative.files.attach(blob)
      blob
    end

    test "resolves English demo assets from the creative's attachments" do
      video = attach("launch.mp4")
      poster = attach("launch-poster.jpg", content_type: "image/jpeg")
      video_dark = attach("launch-dark.mp4")
      poster_dark = attach("launch-dark-poster.jpg", content_type: "image/jpeg")
      # Korean assets on the same creative must NOT leak into the en render.
      ko_video = attach("launch-ko.mp4")

      get "/landing"
      assert_response :success

      assert_includes response.body, video.signed_id
      assert_includes response.body, poster.signed_id
      assert_includes response.body, video_dark.signed_id
      assert_includes response.body, poster_dark.signed_id
      assert_not_includes response.body, ko_video.signed_id
    end

    test "resolves Korean demo assets when locale is ko" do
      en_video = attach("launch.mp4")
      ko_video = attach("launch-ko.mp4")
      ko_poster = attach("launch-ko-poster.jpg", content_type: "image/jpeg")

      get "/landing", params: { locale: "ko" }
      assert_response :success

      assert_includes response.body, ko_video.signed_id
      assert_includes response.body, ko_poster.signed_id
      assert_not_includes response.body, en_video.signed_id
    end

    test "prefers the newest blob when a filename is attached more than once" do
      stale = attach("launch.mp4", created_at: 2.days.ago)
      fresh = attach("launch.mp4", created_at: 1.minute.ago)

      get "/landing"
      assert_response :success

      assert_includes response.body, fresh.signed_id
      assert_not_includes response.body, stale.signed_id
    end

    test "renders no demo section when the creative is absent" do
      @creative.destroy!

      get "/landing"
      assert_response :success

      assert_not_includes response.body, "landing-demo-frame"
    end
  end
end
