# frozen_string_literal: true

require "test_helper"

module Collavre
  class PurgeUnreferencedBlobJobTest < ActiveJob::TestCase
    test "purges an unreferenced blob" do
      blob = ActiveStorage::Blob.create_and_upload!(
        io: StringIO.new("orphan"), filename: "orphan.txt", content_type: "text/plain"
      )

      PurgeUnreferencedBlobJob.perform_now(blob.id)

      assert_not ActiveStorage::Blob.exists?(blob.id)
    end

    test "keeps blobs retained by history" do
      user = users(:one)
      creative = Creative.create!(description: "Current", user: user)
      blob = ActiveStorage::Blob.create_and_upload!(
        io: StringIO.new("history"), filename: "history.txt", content_type: "text/plain"
      )
      change_set = CreativeChangeSet.create!(
        user: user, actor_kind: "human", origin: "editor", status: "applied", applied_at: Time.current
      )
      change = change_set.creative_changes.create!(
        creative: creative, operation: "update", before: {}, after: {}, position: 0
      )
      change.history_file_attachments.create!(name: "history_files", blob: blob)

      PurgeUnreferencedBlobJob.perform_now(blob.id)

      assert ActiveStorage::Blob.exists?(blob.id)
    end
  end
end
