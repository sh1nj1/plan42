# frozen_string_literal: true

require "test_helper"

module Collavre
  module Tools
    class CreativeAttachFilesServiceTest < ActiveSupport::TestCase
      setup do
        @user = users(:one)
        Current.user = @user
        @creative = Creative.create!(description: "<p>x</p>", user: @user)

        @tmp = Dir.mktmpdir
        @file_a = File.join(@tmp, "a.txt")
        @file_b = File.join(@tmp, "b.bin")
        File.write(@file_a, "alpha")
        File.binwrite(@file_b, "\x00\x01\x02")
      end

      teardown do
        FileUtils.remove_entry(@tmp) if @tmp && Dir.exist?(@tmp)
        Current.user = nil
      end

      test "attaches multiple local files and returns public URLs" do
        result = CreativeAttachFilesService.new.call(
          creative_id: @creative.id,
          file_paths: [@file_a, @file_b]
        )

        assert result[:success], result.inspect
        assert_equal 2, result[:attachments].length
        assert_equal "a.txt", result[:attachments][0][:filename]
        assert_match %r{/public-assets/blobs/[^/]+/a\.txt\z}, result[:attachments][0][:url]
        assert_equal 2, @creative.reload.files.count
      end

      test "rejects when user lacks write permission" do
        other = users(:two)
        Current.user = other

        result = CreativeAttachFilesService.new.call(
          creative_id: @creative.id,
          file_paths: [@file_a]
        )

        assert_nil result[:success]
        assert_match(/permission/i, result[:error])
        assert_equal 0, @creative.reload.files.count
      end

      test "returns error when creative not found" do
        result = CreativeAttachFilesService.new.call(
          creative_id: 9_999_999,
          file_paths: [@file_a]
        )
        assert_match(/not found/i, result[:error])
      end

      test "returns error when a file path does not exist" do
        result = CreativeAttachFilesService.new.call(
          creative_id: @creative.id,
          file_paths: [@file_a, "/nope/missing.bin"]
        )
        assert_match(/missing/i, result[:error])
        assert_equal 0, @creative.reload.files.count, "must not attach any when one is missing"
      end
    end
  end
end
