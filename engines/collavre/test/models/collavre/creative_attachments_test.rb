# frozen_string_literal: true

require "test_helper"

module Collavre
  class CreativeAttachmentsTest < ActiveSupport::TestCase
    setup do
      @user = users(:one)
      Current.user = @user
      @creative = Creative.create!(description: "<p>with files</p>", user: @user)
    end

    teardown { Current.user = nil }

    test "creative can attach files" do
      @creative.files.attach(
        io: StringIO.new("hello"),
        filename: "hello.txt",
        content_type: "text/plain"
      )
      assert_equal 1, @creative.files.count
      assert_equal "hello.txt", @creative.files.first.filename.to_s
    end

    test "purge_later on destroy" do
      @creative.files.attach(io: StringIO.new("x"), filename: "x.txt", content_type: "text/plain")
      @creative.destroy
      assert_not ActiveStorage::Attachment.exists?(record_type: "Collavre::Creative", record_id: @creative.id)
    end
  end
end
