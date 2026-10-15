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

    def svg_blob
      @svg_blob ||= ActiveStorage::Blob.create_and_upload!(
        io: StringIO.new('<svg xmlns="http://www.w3.org/2000/svg"><rect width="20" height="20"/></svg>'),
        filename: "image.svg", content_type: "image/svg+xml"
      ).tap { |blob| @creative.files.attach(blob) }
    end

    test "private SVG previews require permission and render inline for the owner" do
      path = url_helpers.rails_storage_proxy_path(svg_blob, only_path: true)
      get path
      assert_response :not_found
      get path, headers: bearer(@stranger)
      assert_response :not_found

      get path, headers: bearer(@owner)
      assert_response :success
      assert_equal svg_blob.download, response.body
      assert_equal "image/svg+xml", response.media_type
      assert_match(/\Ainline;/, response.headers["Content-Disposition"])
      assert_equal SvgStreaming::POLICY, response.headers["Content-Security-Policy"]
      assert_equal "nosniff", response.headers["X-Content-Type-Options"]
      assert_equal "private, no-store", response.headers["Cache-Control"]
    end

    test "SVG redirect URLs use the sandboxed proxy instead of the storage service" do
      get url_helpers.rails_blob_path(svg_blob, only_path: true), headers: bearer(@owner)
      assert_response :redirect
      assert_equal URI(url_helpers.rails_storage_proxy_path(svg_blob, only_path: true)).path,
                   URI(response.location).path
      assert_equal "private, no-store", response.headers["Cache-Control"]
    end

    test "SVG range responses retain image headers and sandboxing" do
      get url_helpers.rails_storage_proxy_path(svg_blob, only_path: true),
          headers: bearer(@owner).merge("Range" => "bytes=0-9")
      assert_response :partial_content
      assert_equal svg_blob.download.byteslice(0, 10), response.body
      assert_equal "image/svg+xml", response.media_type
      assert_equal SvgStreaming::POLICY, response.headers["Content-Security-Policy"]
    end

    test "SVG downloads preserve explicit attachment disposition" do
      get url_helpers.rails_blob_path(svg_blob, disposition: "attachment", only_path: true), headers: bearer(@owner)
      assert_response :redirect
      get response.location, headers: bearer(@owner)
      assert_response :success
      assert_match(/\Aattachment;/, response.headers["Content-Disposition"])
      assert_equal "image/svg+xml", response.media_type
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
    end

    test "redirects to the service URL are never cached, so revocation applies on the next request" do
      sign_in_as(@owner, password: "password")

      %i[blob_redirect representation_redirect].each do |endpoint|
        get endpoints(@blob)[endpoint]
        assert_response :redirect
        assert_equal "private, no-store", response.headers["Cache-Control"], endpoint
      end
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

    test "direct uploads record the uploader, and client metadata cannot publish" do
      sign_in_as(@reader, password: "password")
      params = direct_upload_params
      params[:blob][:metadata] = {
        BlobAccess::UPLOADER_METADATA_KEY => @owner.id.to_s, "public_asset" => true, "custom" => "kept"
      }

      post url_helpers.rails_direct_uploads_path, params: params, as: :json

      assert_response :success
      blob = ActiveStorage::Blob.find_signed!(response.parsed_body["signed_id"])
      assert_equal @reader.id.to_s, blob.metadata[BlobAccess::UPLOADER_METADATA_KEY]
      assert_equal "kept", blob.metadata["custom"]
      assert_not BlobAccess.new(blob, user: nil).readable?
      assert BlobAccess.new(blob, user: @reader).readable?
      assert_not BlobAccess.new(blob, user: @owner).readable?
    end

    test "with forgery protection on, bearer clients may direct upload but cookie sessions need the token" do
      with_forgery_protection do
        post url_helpers.rails_direct_uploads_path, params: direct_upload_params, headers: bearer(@reader), as: :json
        assert_response :success
        blob = ActiveStorage::Blob.find_signed!(response.parsed_body["signed_id"])
        assert_equal @reader.id.to_s, blob.metadata[BlobAccess::UPLOADER_METADATA_KEY]

        post url_helpers.rails_direct_uploads_path, params: direct_upload_params,
          headers: { "Authorization" => "Bearer invalid" }, as: :json
        assert_response :unauthorized
      end

      sign_in_as(@reader, password: "password")
      with_forgery_protection do
        post url_helpers.rails_direct_uploads_path, params: direct_upload_params, as: :json
        assert_response :unprocessable_content
      end
    end

    private

    def with_forgery_protection
      original = ActionController::Base.allow_forgery_protection
      ActionController::Base.allow_forgery_protection = true
      yield
    ensure
      ActionController::Base.allow_forgery_protection = original
    end

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
