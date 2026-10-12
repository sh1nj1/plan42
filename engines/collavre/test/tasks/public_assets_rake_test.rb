# frozen_string_literal: true

require "test_helper"
require "rake"

module Collavre
  class PublicAssetsRakeTest < ActiveSupport::TestCase
    setup do
      @rake = Rake::Application.new
      Rake.application = @rake
      Rake::Task.define_task(:environment)
      load Collavre::Engine.root.join("lib/tasks/public_assets.rake")
      @blob = ActiveStorage::Blob.create_and_upload!(io: StringIO.new("x"), filename: "a.png", content_type: "image/png")
    end

    teardown { Rake.application = Rake::Application.new }

    def run_task(name, signed_ids: nil)
      original = ENV["SIGNED_IDS"]
      ENV["SIGNED_IDS"] = signed_ids
      capture_io { @rake[name].invoke }.first
    ensure
      ENV["SIGNED_IDS"] = original
    end

    test "publish and unpublish toggle the flag for the given signed ids" do
      output = run_task("collavre:public_assets:publish", signed_ids: @blob.signed_id)
      assert_match(/Published 1 blob/, output)
      assert @blob.reload.metadata[BlobAccess::PUBLIC_METADATA_KEY]

      output = run_task("collavre:public_assets:unpublish", signed_ids: @blob.signed_id)
      assert_match(/Unpublished 1 blob/, output)
      assert_nil @blob.reload.metadata[BlobAccess::PUBLIC_METADATA_KEY]
    end

    test "publish_landing publishes landing blobs that exist" do
      output = PublicAssetAllowlist.stub(:landing_signed_ids, [ @blob.signed_id, "missing" ]) do
        run_task("collavre:public_assets:publish_landing")
      end

      assert_match(/Published 1 of 2 landing blob/, output)
    end
  end
end
