# frozen_string_literal: true

require "test_helper"

module Collavre
  class ActiveStorageAccessTest < ActionDispatch::IntegrationTest
    PNG = File.binread(Collavre::Engine.root.join("test/fixtures/files/small.png"))

    setup do
      @owner = users(:one)
      @reader = users(:two)
      @stranger = users(:three)
      Current.user = @owner
      @creative = Creative.create!(description: "<p>x</p>", user: @owner)
      @blob = ActiveStorage::Blob.create_and_upload!(io: StringIO.new(PNG), filename: "small.png", content_type: "image/png")
      @creative.files.attach(@blob)
      @app = Doorkeeper::Application.create!(
        name: "Blob App", redirect_uri: "urn:ietf:wg:oauth:2.0:oob", owner: @owner, confidential: true, scopes: "public"
      )
    end

    teardown { Current.user = nil }

    def url_helpers
      Rails.application.routes.url_helpers
    end

    def endpoints(blob)
      variant = blob.variant(resize_to_limit: [ 10, 10 ])
      {
        blob_redirect: url_helpers.rails_blob_path(blob, only_path: true),
        blob_proxy: url_helpers.rails_storage_proxy_path(blob, only_path: true),
        representation_redirect: url_helpers.rails_representation_path(variant, only_path: true),
        representation_proxy: url_helpers.rails_storage_proxy_path(variant, only_path: true)
      }
    end

    def bearer(user)
      token = Doorkeeper::AccessToken.create!(application: @app, resource_owner_id: user.id, scopes: "public").token
      { "Authorization" => "Bearer #{token}" }
    end

    test "anonymous requests for a private blob get 404 on every endpoint" do
      endpoints(@blob).each do |name, path|
        get path
        assert_response :not_found, name
      end
    end

    test "a user without access gets 404" do
      endpoints(@blob).each do |name, path|
        get path, headers: bearer(@stranger)
        assert_response :not_found, name
      end
    end

    test "the owner is served with a private, non-indexable response" do
      sign_in_as(@owner, password: "password")

      get endpoints(@blob)[:blob_proxy]
      assert_response :success
      assert_equal PNG.b, response.body.b
      assert_equal "private, no-store", response.headers["Cache-Control"]
      assert_equal "noindex, nofollow", response.headers["X-Robots-Tag"]

      get endpoints(@blob)[:blob_redirect]
      assert_response :redirect
      assert_match(/private/, response.headers["Cache-Control"])
    end

    test "representations are served to authorized viewers" do
      sign_in_as(@owner, password: "password")

      get endpoints(@blob)[:representation_redirect]
      assert_response :redirect

      get endpoints(@blob)[:representation_proxy]
      assert_response :success
      assert_equal "private, no-store", response.headers["Cache-Control"]
    end

    test "a shared reader may fetch with a bearer token, and loses access once unshared" do
      share = perform_enqueued_jobs { CreativeShare.create!(creative: @creative, user: @reader, permission: :read) }

      get endpoints(@blob)[:blob_proxy], headers: bearer(@reader)
      assert_response :success

      perform_enqueued_jobs { share.destroy! }
      get endpoints(@blob)[:blob_proxy], headers: bearer(@reader)
      assert_response :not_found
    end

    test "the shared Kollavy agent stays confined to its task tree" do
      agent = Collavre::Kollavy.seed!
      CreativeShare.create!(creative: @creative, user: agent, permission: :read)
      Current.reset

      get endpoints(@blob)[:blob_proxy], headers: bearer(agent)

      assert_response :not_found
    end

    test "revoked bearer tokens are rejected" do
      headers = bearer(@owner)
      Doorkeeper::AccessToken.find_by(resource_owner_id: @owner.id, application: @app).revoke

      get endpoints(@blob)[:blob_proxy], headers: headers
      assert_response :not_found
    end

    test "expired sessions do not authorize" do
      sign_in_as(@owner, password: "password")
      Collavre::Session.update_all(last_active_at: 1.year.ago)
      Collavre::SystemSetting.stub(:session_timeout_enabled?, true) do
        get endpoints(@blob)[:blob_proxy]
      end
      assert_response :not_found
    end

    test "publicly shared blobs are readable anonymously" do
      perform_enqueued_jobs { CreativeShare.create!(creative: @creative, user: nil, permission: :read) }

      get endpoints(@blob)[:blob_proxy]
      assert_response :success
      assert_equal "private, no-store", response.headers["Cache-Control"]
    end

    test "invalid signed ids get 404" do
      get "/rails/active_storage/blobs/proxy/not-valid/small.png"
      assert_response :not_found
    end

    test "endpoints reject requests that bypass CloudFront when an origin secret is set" do
      sign_in_as(@owner, password: "password")
      with_origin_secret("secret123") do
        get endpoints(@blob)[:blob_proxy]
        assert_response :forbidden

        get endpoints(@blob)[:blob_proxy], headers: { "X-Origin-Secret" => "secret123" }
        assert_response :success

        post url_helpers.rails_direct_uploads_path, params: direct_upload_params, as: :json
        assert_response :forbidden

        get "/rails/active_storage/disk/invalid/small.png"
        assert_response :forbidden
      end
    end

    test "direct uploads require authentication" do
      post url_helpers.rails_direct_uploads_path, params: direct_upload_params, as: :json

      assert_response :unauthorized
    end

    test "direct uploads record the uploader, overriding client metadata" do
      sign_in_as(@reader, password: "password")
      params = direct_upload_params
      params[:blob][:metadata] = {
        BlobAccess::UPLOADER_METADATA_KEY => @owner.id.to_s, BlobAccess::PUBLIC_METADATA_KEY => true, "custom" => "kept"
      }

      post url_helpers.rails_direct_uploads_path, params: params, as: :json

      assert_response :success
      blob = ActiveStorage::Blob.find_signed!(response.parsed_body["signed_id"])
      assert_equal @reader.id.to_s, blob.metadata[BlobAccess::UPLOADER_METADATA_KEY]
      assert_equal "kept", blob.metadata["custom"]
      assert_nil blob.metadata[BlobAccess::PUBLIC_METADATA_KEY]
      assert BlobAccess.new(blob, user: @reader).readable?
      assert_not BlobAccess.new(blob, user: @owner).readable?
    end

    private

    def direct_upload_params
      {
        blob: {
          filename: "upload.png", byte_size: PNG.bytesize, content_type: "image/png",
          checksum: OpenSSL::Digest::MD5.base64digest(PNG)
        }
      }
    end

    def with_origin_secret(secret)
      original = Collavre::IntegrationSettings.method(:fetch)
      Collavre::IntegrationSettings.stub(:fetch, ->(k, *args, **kw) { k.to_sym == :origin_shared_secret ? secret : original.call(k, *args, **kw) }) do
        yield
      end
    end
  end
end
