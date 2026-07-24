# frozen_string_literal: true

require "test_helper"

module Collavre
  module Tools
    class CreativeListAttachmentsServiceTest < ActiveSupport::TestCase
      setup do
        @user = users(:one)
        Current.user = @user
        @creative = Creative.create!(description: "<p>x</p>", user: @user)
        @creative.files.attach(io: StringIO.new("a"), filename: "a.txt", content_type: "text/plain")
        @creative.files.attach(io: StringIO.new("b"), filename: "b.txt", content_type: "text/plain")
      end

      teardown { Current.user = nil }

      test "lists all attachments with public URLs" do
        result = CreativeListAttachmentsService.new.call(creative_id: @creative.id)
        assert result[:success]
        assert_equal 2, result[:attachments].length
        filenames = result[:attachments].map { |a| a[:filename] }
        assert_includes filenames, "a.txt"
        assert_includes filenames, "b.txt"
        assert(result[:attachments].all? { |a| a[:url].include?("/public-assets/blobs/") })
      end

      test "rejects when user lacks read permission" do
        other = users(:two)
        Current.user = other

        result = CreativeListAttachmentsService.new.call(creative_id: @creative.id)
        assert_match(/permission/i, result[:error])
      end

      test "returns error when creative not found" do
        result = CreativeListAttachmentsService.new.call(creative_id: 9_999_999)
        assert_match(/not found/i, result[:error])
      end
    end
  end
end
