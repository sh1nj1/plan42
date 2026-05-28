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

    test "serves blob content via signed_id without auth" do
      get "/public-assets/blobs/#{@blob.signed_id}/hello.txt"
      assert_response :success
      assert_equal "hello world", response.body
      assert_equal "text/plain", response.media_type
    end

    test "sets long-TTL public Cache-Control" do
      get "/public-assets/blobs/#{@blob.signed_id}/hello.txt"
      cache_control = response.headers["Cache-Control"].to_s
      assert_match(/public/, cache_control)
      assert_match(/max-age=31536000/, cache_control)
      assert_match(/immutable/, cache_control)
    end

    test "returns 404 for bad signed_id" do
      get "/public-assets/blobs/not-a-valid-signed-id/hello.txt"
      assert_response :not_found
    end
  end
end
