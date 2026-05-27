# frozen_string_literal: true

require "test_helper"

module Collavre
  module Tools
    class CreativeRemoveAttachmentServiceTest < ActiveSupport::TestCase
      setup do
        @user = users(:one)
        Current.user = @user
        @creative = Creative.create!(description: "<p>x</p>", user: @user)
        @creative.files.attach(io: StringIO.new("a"), filename: "a.txt", content_type: "text/plain")
        @attachment = @creative.files.first
        @signed_id = @attachment.blob.signed_id
      end

      teardown { Current.user = nil }

      test "removes the attachment by signed_id" do
        result = CreativeRemoveAttachmentService.new.call(
          creative_id: @creative.id,
          signed_id: @signed_id
        )
        assert result[:success]
        assert_equal 0, @creative.reload.files.count
      end

      test "rejects when user lacks write permission" do
        other = users(:two)
        Current.user = other

        result = CreativeRemoveAttachmentService.new.call(
          creative_id: @creative.id,
          signed_id: @signed_id
        )
        assert_match(/permission/i, result[:error])
        assert_equal 1, @creative.reload.files.count
      end

      test "errors when signed_id does not belong to this creative" do
        other = Creative.create!(description: "<p>y</p>", user: @user)
        other.files.attach(io: StringIO.new("z"), filename: "z.txt", content_type: "text/plain")
        other_signed = other.files.first.blob.signed_id

        result = CreativeRemoveAttachmentService.new.call(
          creative_id: @creative.id,
          signed_id: other_signed
        )
        assert_match(/not found/i, result[:error])
        assert_equal 1, @creative.reload.files.count
      end
    end
  end
end
