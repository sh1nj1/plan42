# frozen_string_literal: true

require "test_helper"

module Collavre
  class BlobAccessTest < ActiveSupport::TestCase
    setup do
      @owner = users(:one)
      @reader = users(:two)
      @stranger = users(:three)
      Current.user = @owner
      @creative = Creative.create!(description: "<p>private</p>", user: @owner)
    end

    teardown { Current.user = nil }

    def blob(name = "f.txt")
      content_type = name.end_with?(".png") ? "image/png" : "text/plain"
      ActiveStorage::Blob.create_and_upload!(io: StringIO.new("x"), filename: name, content_type: content_type)
    end

    def readable?(blob, user)
      BlobAccess.new(blob, user: user).readable?
    end

    def share(creative, user, permission)
      perform_enqueued_jobs { CreativeShare.create!(creative: creative, user: user, permission: permission) }
    end

    test "creative file follows the creative read permission" do
      @creative.files.attach(blob)
      file = @creative.files.first.blob

      assert readable?(file, @owner)
      assert_not readable?(file, @stranger)
      assert_not readable?(file, nil)

      share(@creative, @reader, :read)
      assert readable?(file, @reader)
      assert_not readable?(file, nil)
    end

    test "public share makes a creative file readable anonymously" do
      @creative.files.attach(blob)
      share(@creative, nil, :read)

      assert readable?(@creative.files.first.blob, nil)
      assert readable?(@creative.files.first.blob, @stranger)
    end

    test "explicit no_access entry beats the public share" do
      @creative.files.attach(blob)
      share(@creative, nil, :read)
      share(@creative, @stranger, :no_access)

      assert_not readable?(@creative.files.first.blob, @stranger)
      assert readable?(@creative.files.first.blob, @reader)
    end

    test "comment image follows the comment creative" do
      comment = Comment.create!(creative: @creative, user: @owner, content: "hi")
      comment.images.attach(blob("p.png"))
      image = comment.images.first.blob

      assert readable?(image, @owner)
      assert_not readable?(image, @stranger)

      share(@creative, @reader, :read)
      assert readable?(image, @reader)
    end

    test "private comment image is limited to its author and approver" do
      share(@creative, @reader, :read)
      comment = Comment.create!(creative: @creative, user: @owner, content: "secret", private: true)
      comment.images.attach(blob("p.png"))
      image = comment.images.first.blob

      assert readable?(image, @owner)
      assert_not readable?(image, @reader)

      comment.update_column(:approver_id, @reader.id)
      assert readable?(image, @reader)
    end

    test "missing comment record denies access" do
      comment = Comment.create!(creative: @creative, user: @owner, content: "hi")
      comment.images.attach(blob("p.png"))
      image = comment.images.first.blob
      comment.images.first.update_column(:record_id, 0)

      assert_not readable?(image, @owner)
    end

    test "history snapshot follows the changed creative, falling back to the anchor" do
      change_set = CreativeChangeSet.create!(
        anchor_creative: @creative, anchor_source: "agent_topic", user: @owner,
        actor_kind: "agent", origin: "tool", status: "draft"
      )
      change = change_set.creative_changes.create!(creative_id: -1, operation: "create", before: {}, after: {}, position: 0)
      file = blob
      change.history_file_attachments.create!(name: "history_files", blob: file)

      assert readable?(file, @owner)
      assert_not readable?(file, @stranger)
    end

    test "missing history change denies access" do
      file = blob
      ActiveStorage::Attachment.insert_all!([ { name: "history_files", record_type: CreativeChange.name, record_id: 0, blob_id: file.id, created_at: Time.current } ])

      assert_not readable?(file, @owner)
    end

    test "avatar is readable by anyone" do
      @stranger.avatar.attach(blob("a.png"))

      assert readable?(@stranger.avatar.blob, nil)
    end

    test "unknown record types deny access" do
      file = blob
      ActiveStorage::Attachment.insert_all!([ { name: "files", record_type: "Unknown::Thing", record_id: 1, blob_id: file.id, created_at: Time.current } ])

      assert_not readable?(file, @owner)
    end

    test "unattached blob is readable by its uploader" do
      file = blob
      file.update!(metadata: file.metadata.merge(BlobAccess::UPLOADER_METADATA_KEY => @reader.id.to_s))

      assert readable?(file, @reader)
      assert_not readable?(file, @stranger)
      assert_not readable?(file, nil)
    end

    test "an embedding does not expose an unattached upload beyond its uploader" do
      file = blob
      file.update!(metadata: file.metadata.merge(BlobAccess::UPLOADER_METADATA_KEY => @reader.id.to_s))
      Creative.create!(description: %(<img src="/public-assets/blobs/#{file.signed_id}/f.txt">), user: @stranger)

      assert_not readable?(file, @stranger)
      assert readable?(file, @reader)
    end

    test "unattached blob embedded in a readable description is readable" do
      file = blob
      @creative.update_column(:description, %(<img src="/public-assets/blobs/#{file.signed_id}/f.txt">))

      assert readable?(file, @owner)
      assert_not readable?(file, @stranger)
    end
  end
end
