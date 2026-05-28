# frozen_string_literal: true

require "test_helper"

module Collavre
  module Tools
    class CreativeAttachFilesServiceTest < ActiveSupport::TestCase
      setup do
        @user = users(:one)
        Current.user = @user
        @creative = Creative.create!(description: "<p>x</p>", user: @user)

        @upload_root = Dir.mktmpdir
        @prev_upload_root = ENV["MCP_UPLOAD_ROOT"]
        ENV["MCP_UPLOAD_ROOT"] = @upload_root

        @tmp = Dir.mktmpdir(nil, @upload_root)
        @file_a = File.join(@tmp, "a.txt")
        @file_b = File.join(@tmp, "b.bin")
        File.write(@file_a, "alpha")
        File.binwrite(@file_b, "\x00\x01\x02")

        @outside_dir = Dir.mktmpdir
        @outside_file = File.join(@outside_dir, "secret.txt")
        File.write(@outside_file, "top secret")
      end

      teardown do
        FileUtils.remove_entry(@tmp) if @tmp && Dir.exist?(@tmp)
        FileUtils.remove_entry(@upload_root) if @upload_root && Dir.exist?(@upload_root)
        FileUtils.remove_entry(@outside_dir) if @outside_dir && Dir.exist?(@outside_dir)
        ENV["MCP_UPLOAD_ROOT"] = @prev_upload_root
        Current.user = nil
      end

      test "attaches multiple local files and returns public URLs" do
        result = CreativeAttachFilesService.new.call(
          creative_id: @creative.id,
          file_paths: [ @file_a, @file_b ]
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
          file_paths: [ @file_a ]
        )

        assert_nil result[:success]
        assert_match(/permission/i, result[:error])
        assert_equal 0, @creative.reload.files.count
      end

      test "returns error when creative not found" do
        result = CreativeAttachFilesService.new.call(
          creative_id: 9_999_999,
          file_paths: [ @file_a ]
        )
        assert_match(/not found/i, result[:error])
      end

      test "returns error when a file path does not exist" do
        result = CreativeAttachFilesService.new.call(
          creative_id: @creative.id,
          file_paths: [ @file_a, File.join(@upload_root, "nope/missing.bin") ]
        )
        assert_match(/missing/i, result[:error])
        assert_equal 0, @creative.reload.files.count, "must not attach any when one is missing"
      end

      test "rejects file paths outside the upload root" do
        result = CreativeAttachFilesService.new.call(
          creative_id: @creative.id,
          file_paths: [ @file_a, @outside_file ]
        )

        assert_nil result[:success]
        assert_match(/outside/i, result[:error])
        assert_includes result[:outside], @outside_file
        assert_equal 0, @creative.reload.files.count, "must not attach any when one escapes upload root"
      end

      test "rejects symlinks that escape the upload root" do
        symlink = File.join(@tmp, "evil.lnk")
        File.symlink(@outside_file, symlink)

        result = CreativeAttachFilesService.new.call(
          creative_id: @creative.id,
          file_paths: [ symlink ]
        )

        assert_nil result[:success]
        assert_match(/outside/i, result[:error])
        assert_equal 0, @creative.reload.files.count
      end
    end
  end
end
