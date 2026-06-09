require "test_helper"

module Collavre
  module Creatives
    class AttachmentsControllerTest < ActionDispatch::IntegrationTest
      setup do
        @owner = users(:two)   # non-admin owner
        @other = users(:three) # non-admin, no share
        @app = Doorkeeper::Application.create!(
          name: "Test App", redirect_uri: "urn:ietf:wg:oauth:2.0:oob", owner: @owner, confidential: true, scopes: "public"
        )
      end

      def token_for(user)
        Doorkeeper::AccessToken.create!(application: @app, resource_owner_id: user.id, scopes: "public").token
      end

      def upload(content_type: "image/png", filename: "pic.png", bytes: "bytes")
        Rack::Test::UploadedFile.new(StringIO.new(bytes), content_type, original_filename: filename)
      end

      def path_for(creative)
        Collavre::Engine.routes.url_helpers.creative_attachments_path(creative)
      end

      test "401 without bearer token" do
        creative = Collavre::Creative.create!(description: "<p>x</p>", user: @owner)
        post path_for(creative), params: { file: upload }
        assert_response :unauthorized
      end

      test "403 without write permission" do
        creative = Collavre::Creative.create!(description: "<p>x</p>", user: @owner)
        post path_for(creative),
             params: { file: upload },
             headers: { "Authorization" => "Bearer #{token_for(@other)}" }
        assert_response :forbidden
      end

      test "uploads an image, embeds <img>, attaches to creative.files" do
        creative = Collavre::Creative.create!(description: "<p>x</p>", user: @owner)
        post path_for(creative),
             params: { file: upload(content_type: "image/png", filename: "pic.png") },
             headers: { "Authorization" => "Bearer #{token_for(@owner)}" }
        assert_response :success
        body = JSON.parse(response.body)
        assert body["signed_id"].present?
        assert_equal "pic.png", body["filename"]
        creative.reload
        assert_includes creative.description, "<img"
        assert_includes creative.description, body["signed_id"]
        assert_includes creative.files.map { |f| f.blob.signed_id }, body["signed_id"]
      end

      test "uploads an mp4 and embeds <video controls>" do
        creative = Collavre::Creative.create!(description: "<p>x</p>", user: @owner)
        post path_for(creative),
             params: { file: upload(content_type: "video/mp4", filename: "clip.mp4") },
             headers: { "Authorization" => "Bearer #{token_for(@owner)}" }
        assert_response :success
        creative.reload
        assert_includes creative.description, "<video"
        assert_includes creative.description, "controls"
      end

      test "422 when no file param" do
        creative = Collavre::Creative.create!(description: "<p>x</p>", user: @owner)
        post path_for(creative),
             headers: { "Authorization" => "Bearer #{token_for(@owner)}" }
        assert_response :unprocessable_entity
      end
    end
  end
end
