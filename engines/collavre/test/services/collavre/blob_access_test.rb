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

    def embed(file)
      "<p><img src=\"/rails/active_storage/blobs/redirect/#{file.signed_id}/f.png\"></p>"
    end

    def change_set_for(anchor, status: "applied")
      CreativeChangeSet.create!(
        anchor_creative: anchor, anchor_source: "agent_topic", user: @owner,
        actor_kind: "agent", origin: "tool", status: status
      )
    end

    # Records a change the way History does: each snapshot carries the
    # permission path of the placement it was captured in.
    def history_change(creative, before:, after:, change_set: change_set_for(creative))
      change = change_set.creative_changes.new(
        creative_id: creative.id, operation: "update",
        **Creatives::HistoricalSnapshotAuthorization.initial_attributes(creative, before, 0)
      )
      change.assign_attributes(Creatives::HistoricalSnapshotAuthorization.after_attributes(change, creative, after))
      change.save!
      change
    end

    def retain(change, file)
      change.history_file_attachments.create!(name: "history_files", blob: file)
    end

    test "history file follows the visibility of the snapshot that references it" do
      file = blob
      change = history_change(@creative, before: { "description" => embed(file) }, after: { "description" => "<p>gone</p>" })
      retain(change, file)
      share(@creative, @reader, :read)

      assert readable?(file, @owner)
      assert readable?(file, @reader)
      assert_not readable?(file, @stranger)
      assert_not readable?(file, nil)
    end

    test "history file of a creative moved into a public tree stays private" do
      public_tree = Creative.create!(description: "<p>public</p>", user: @owner)
      share(public_tree, nil, :read)
      child = Creative.create!(description: "<p>child</p>", user: @owner, parent: @creative)
      file = blob
      change = history_change(child, before: { "description" => embed(file), "parent_id" => @creative.id },
                                     after: { "description" => "<p>gone</p>", "parent_id" => @creative.id })
      retain(change, file)

      perform_enqueued_jobs { child.update!(parent: public_tree) }

      assert Creatives::PermissionFilter.new(user: nil).readable_ids([ child.id ]).any?
      assert_not readable?(file, nil)
      assert_not readable?(file, @stranger)
      assert readable?(file, @owner)
    end

    test "history file is not readable through a snapshot that does not reference it" do
      file = blob
      change = history_change(@creative, before: { "description" => "<p>a</p>" }, after: { "description" => "<p>b</p>" })
      retain(change, file)

      assert_not readable?(file, @owner)
    end

    test "history file of a draft create follows its intended parent" do
      file = blob
      change_set = change_set_for(@creative, status: "draft")
      change = change_set.creative_changes.create!(
        creative_id: -1, operation: "create", before: {}, position: 0,
        after: { "description" => embed(file), "parent_id" => @creative.id }
      )
      retain(change, file)

      assert readable?(file, @owner)
      assert_not readable?(file, @stranger)
    end

    test "history snapshot of a real creative does not borrow the anchor's readers" do
      hidden = Creative.create!(description: "<p>hidden</p>", user: @owner)
      file = blob
      change = history_change(hidden, before: { "description" => embed(file) }, after: { "description" => "<p>x</p>" },
                                      change_set: change_set_for(@creative, status: "draft"))
      retain(change, file)
      share(@creative, @stranger, :read)

      assert readable?(file, @owner)
      assert_not readable?(file, @stranger)
    end

    test "history file of a hard-deleted creative is limited to the deleting actor" do
      doomed = Creative.create!(description: "<p>doomed</p>", user: @owner, parent: @creative)
      share(@creative, @reader, :read)
      file = blob
      change = history_change(doomed, before: { "description" => embed(file), "parent_id" => @creative.id }, after: {})
      retain(change, file)
      doomed.destroy!

      assert readable?(file, @owner)
      assert_not readable?(file, @reader)
    end

    test "an unverifiable signed id in a snapshot is ignored" do
      file = blob
      change = history_change(@creative, before: { "description" => "<img src=\"/rails/active_storage/blobs/redirect/bogus/f.png\">" },
                                         after: { "description" => "<p>b</p>" })
      retain(change, file)

      assert_not readable?(file, @owner)
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
