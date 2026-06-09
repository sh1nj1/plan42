# frozen_string_literal: true

require "test_helper"

module Collavre
  module Tools
    class CreativeAttachFilesServiceTest < ActiveSupport::TestCase
      setup do
        @user = users(:one)
        Current.user = @user
        @creative = Creative.create!(description: "<p>x</p>", user: @user)
      end

      teardown do
        Current.user = nil
      end

      test "attaches inline text content, embeds it, and returns public URLs" do
        result = CreativeAttachFilesService.new.call(
          creative_id: @creative.id,
          files: [
            { "filename" => "notes.md", "content" => "# Hello", "content_type" => "text/markdown" },
            { "filename" => "data.txt", "content" => "alpha" }
          ]
        )

        assert result[:success], result.inspect
        assert_equal 2, result[:attachments].length
        assert_equal "notes.md", result[:attachments][0][:filename]
        assert_match %r{/public-assets/blobs/[^/]+/notes\.md\z}, result[:attachments][0][:url]

        @creative.reload
        result[:attachments].each do |a|
          assert_includes @creative.description, a[:signed_id]
          assert_includes @creative.files.map { |f| f.blob.signed_id }, a[:signed_id]
        end
      end

      test "rejects when user lacks write permission" do
        Current.user = users(:two)
        # creative owned by users(:one); users(:two) is non-admin with no share
        creative = Creative.create!(description: "<p>x</p>", user: users(:three))
        Current.user = users(:two)

        result = CreativeAttachFilesService.new.call(
          creative_id: creative.id,
          files: [ { "filename" => "a.txt", "content" => "x" } ]
        )

        assert_nil result[:success]
        assert_match(/permission/i, result[:error])
        assert_equal 0, creative.reload.files.count
      end

      test "returns error when creative not found" do
        result = CreativeAttachFilesService.new.call(
          creative_id: 9_999_999,
          files: [ { "filename" => "a.txt", "content" => "x" } ]
        )
        assert_match(/not found/i, result[:error])
      end

      test "attaches to the effective origin when given a linked creative" do
        # Agents often operate on the visible linked row id. Linked rows cannot
        # change their own description, so the content must land on the origin
        # instead of raising during update! and orphaning the blob.
        origin = @creative
        linked = Creative.create!(origin: origin, user: @user)

        result = CreativeAttachFilesService.new.call(
          creative_id: linked.id,
          files: [ { "filename" => "notes.md", "content" => "# Hi", "content_type" => "text/markdown" } ]
        )

        assert result[:success], result.inspect
        sid = result[:attachments][0][:signed_id]
        origin.reload
        assert_includes origin.description, sid
        assert_includes origin.files.map { |f| f.blob.signed_id }, sid
        assert_not_includes linked.reload.description.to_s, sid
      end

      test "returns error when no files provided" do
        result = CreativeAttachFilesService.new.call(creative_id: @creative.id, files: [])
        assert_nil result[:success]
        assert_match(/no files/i, result[:error])
      end

      test "rejects a GitHub-synced creative and creates no orphan blob" do
        # GitHub-synced creatives reject description changes, so embedding would
        # raise and orphan the freshly-created blobs. Reject before creating any.
        creative = Creative.create!(
          description: "<p>synced</p>", user: @user,
          data: { "source" => { "type" => "github_markdown" } }
        )
        assert_no_difference -> { ActiveStorage::Blob.count } do
          result = CreativeAttachFilesService.new.call(
            creative_id: creative.id,
            files: [ { "filename" => "notes.md", "content" => "# Hi" } ]
          )
          assert_nil result[:success]
          assert_match(/github/i, result[:error])
        end
        assert_not_includes creative.reload.description.to_s, "notes.md"
      end

      test "returns error when a file is missing a filename" do
        result = CreativeAttachFilesService.new.call(
          creative_id: @creative.id,
          files: [ { "content" => "x" } ]
        )
        assert_nil result[:success]
        assert_match(/filename/i, result[:error])
      end
    end
  end
end
