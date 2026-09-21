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

    test "stale attachment embedding preserves newly committed type and body" do
      blob = ActiveStorage::Blob.create_and_upload!(io: StringIO.new("file"), filename: "test.txt", content_type: "text/plain")
      @creative.update!(content_type_input: "markdown", markdown_source: "Old body")
      stale = Creative.find(@creative.id)
      latest = Creative.find(@creative.id)
      latest.update!(content_type_input: "markdown", markdown_source: "New body", data: latest.data.merge("kind" => "project"))

      stale.embed_attachment_blob!(blob)

      assert_equal "project", @creative.reload.creative_type
      assert_includes @creative.description, "New body"
      assert_includes @creative.description, blob.signed_id
      assert_nil @creative.data["content_type"]
    end

    test "stale attachment removal preserves newly committed type and body" do
      blob = ActiveStorage::Blob.create_and_upload!(io: StringIO.new("file"), filename: "test.txt", content_type: "text/plain")
      node = @creative.attachment_node_html(blob)
      @creative.update!(content_type_input: "markdown", markdown_source: "Old body\n\n#{node}")
      stale = Creative.find(@creative.id)
      latest = Creative.find(@creative.id)
      latest.update!(content_type_input: "markdown", markdown_source: "New body\n\n#{node}", data: latest.data.merge("kind" => "project"))

      assert stale.remove_attachment!(blob.signed_id)

      assert_equal "project", @creative.reload.creative_type
      assert_includes @creative.description, "New body"
      refute_includes @creative.description, blob.signed_id
      assert_nil @creative.data["content_type"]
    end

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
