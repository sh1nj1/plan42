# frozen_string_literal: true

require "test_helper"

module Collavre
  class PublicAssetsControllerTest < ActionDispatch::IntegrationTest
    setup do
      @user = users(:one)
      Current.user = @user
      @creative = Creative.create!(description: "<p>x</p>", user: @user)
      @creative.files.attach(
        io: StringIO.new("hello world"),
        filename: "hello.txt",
        content_type: "text/plain"
      )
      @blob = @creative.files.first.blob
      # In transactional tests, the after_commit hook that uploads the blob to
      # the service doesn't run (outer transaction rolls back). Upload manually
      # so the controller can stream the content from the disk service.
      @blob.upload(StringIO.new("hello world")) unless @blob.service.exist?(@blob.key)
    end

    teardown { Current.user = nil }

    def publish(creative)
      perform_enqueued_jobs { CreativeShare.create!(creative: creative, user: nil, permission: :read) }
    end

    test "serves a publicly shared blob without auth and caches it publicly" do
      publish(@creative)

      get "/public-assets/blobs/#{@blob.signed_id}/hello.txt"

      assert_response :success
      assert_equal "hello world", response.body
      assert_equal "text/plain", response.media_type
      cache_control = response.headers["Cache-Control"].to_s
      assert_match(/public/, cache_control)
      assert_match(/s-maxage=86400/, cache_control)
      assert_no_match(/immutable/, cache_control)
      assert CdnInvalidation.publicly_cached?(@blob.reload)
    end

    test "serves public HTML attachments as binary downloads without executing HTML" do
      publish(@creative)
      content = "<!doctype html><h1>Report</h1><script>alert(1)</script>"
      @creative.files.attach(io: StringIO.new(content), filename: "report.html", content_type: "text/html")
      blob = @creative.files.blobs.find_by(filename: "report.html")
      blob.upload(StringIO.new(content)) unless blob.service.exist?(blob.key)

      get "/public-assets/blobs/#{blob.signed_id}/report.html"

      assert_response :success
      assert_equal content, response.body
      assert_equal "application/octet-stream", response.media_type
      assert_match(/\Aattachment;/, response.headers["Content-Disposition"])
      assert_includes response.headers["Content-Disposition"], 'filename="report.html"'
    end

    test "serves public SVG images inline with a sandbox policy" do
      publish(@creative)
      content = '<svg xmlns="http://www.w3.org/2000/svg"><script>alert(1)</script><rect width="20" height="20"/></svg>'
      blob = ActiveStorage::Blob.create_and_upload!(
        io: StringIO.new(content), filename: "image.svg", content_type: "image/svg+xml"
      )
      @creative.files.attach(blob)

      get "/public-assets/blobs/#{blob.signed_id}/image.svg"

      assert_response :success
      assert_equal content, response.body
      assert_equal "image/svg+xml", response.media_type
      assert_match(/\Ainline;/, response.headers["Content-Disposition"])
      assert_equal SvgStreaming::POLICY, response.headers["Content-Security-Policy"]
      assert_equal "nosniff", response.headers["X-Content-Type-Options"]
      assert_includes response.headers["Cache-Control"], "public"
    end

    test "redirects a private blob to the authorized proxy without caching" do
      get "/public-assets/blobs/#{@blob.signed_id}/hello.txt"

      assert_response :found
      assert_equal Rails.application.routes.url_helpers.rails_storage_proxy_path(@blob, only_path: true),
                   URI(response.location).path
      assert_equal "private, no-store", response.headers["Cache-Control"]
      assert_not_equal "hello world", response.body
      assert_not CdnInvalidation.publicly_cached?(@blob.reload)
    end

    test "private blob stays private for a signed-in owner (no public caching)" do
      sign_in_as(@user, password: "password")

      get "/public-assets/blobs/#{@blob.signed_id}/hello.txt"

      assert_response :found
      follow_redirect!
      assert_response :success
      assert_equal "hello world", response.body
      assert_equal "private, no-store", response.headers["Cache-Control"]
    end

    test "redirects to the app host when assets are served from a CDN domain" do
      with_integration_setting(:public_assets_host, "https://cdn.example.com") do
        Rails.application.routes.stub(:default_url_options, { host: "app.example.com", protocol: "https" }) do
          get "/public-assets/blobs/#{@blob.signed_id}/hello.txt", headers: { "Host" => "cdn.example.com" }
        end
      end

      assert_response :found
      assert_match %r{\Ahttps://app\.example\.com/rails/active_storage/blobs/proxy/}, response.location
    end

    test "does not serve publicly when the blob is unpublished while it is marked" do
      PublicAssetAllowlist.publish!([ @blob.signed_id ])
      unpublish = ->(_blob) { PublicAssetAllowlist.unpublish!([ @blob.signed_id ]) }

      CdnInvalidation.stub(:mark_publicly_cached, unpublish) do
        get "/public-assets/blobs/#{@blob.signed_id}/hello.txt"
      end

      assert_response :found
      assert_equal "private, no-store", response.headers["Cache-Control"]
    end

    test "returns 404 for bad signed_id" do
      get "/public-assets/blobs/not-a-valid-signed-id/hello.txt"
      assert_response :not_found
    end

    test "rejects requests that bypass CloudFront when an origin secret is set" do
      publish(@creative)
      with_integration_setting(:origin_shared_secret, "secret123") do
        get "/public-assets/blobs/#{@blob.signed_id}/hello.txt"
        assert_response :forbidden

        get "/public-assets/blobs/#{@blob.signed_id}/hello.txt", headers: { "X-Origin-Secret" => "secret123" }
        assert_response :success
      end
    end

    private

    def with_integration_setting(key, value)
      original = Collavre::IntegrationSettings.method(:fetch)
      Collavre::IntegrationSettings.stub(:fetch, ->(k, *args, **kw) { k.to_sym == key ? value : original.call(k, *args, **kw) }) do
        yield
      end
    end
  end
end
