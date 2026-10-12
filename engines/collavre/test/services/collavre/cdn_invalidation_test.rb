# frozen_string_literal: true

require "test_helper"

module Collavre
  class CdnInvalidationTest < ActiveSupport::TestCase
    setup do
      @owner = users(:one)
      Current.user = @owner
      @creative = Creative.create!(description: "<p>x</p>", user: @owner)
      @blob = ActiveStorage::Blob.create_and_upload!(io: StringIO.new("x"), filename: "f.txt", content_type: "text/plain")
    end

    teardown { Current.user = nil }

    def with_distribution(id = "E123", &block)
      CdnInvalidation.stub(:distribution_id, id, &block)
    end

    # The test env runs jobs inline, so record perform_later calls instead.
    def recorded_invalidations
      recorded = []
      CdnInvalidationJob.stub(:perform_later, ->(paths) { recorded << paths }) { yield }
      recorded
    end

    test "marks a blob as publicly cached once, without touching attached records" do
      @creative.files.attach(@blob)
      updated_at = @creative.reload.updated_at

      CdnInvalidation.mark_publicly_cached(@blob)
      CdnInvalidation.mark_publicly_cached(@blob)

      assert CdnInvalidation.publicly_cached?(@blob.reload)
      assert_equal updated_at, @creative.reload.updated_at
    end

    test "marking a stale blob cannot restore a concurrently revoked public flag" do
      PublicAssetAllowlist.publish!([ @blob.signed_id ])
      stale = ActiveStorage::Blob.find(@blob.id)
      PublicAssetAllowlist.unpublish!([ @blob.signed_id ])

      CdnInvalidation.mark_publicly_cached(stale)

      assert CdnInvalidation.publicly_cached?(@blob)
      assert_not BlobAccess.new(@blob.reload, user: nil).readable?
    end

    test "the cached marker survives a stale blob metadata write (ActiveStorage analysis)" do
      stale = ActiveStorage::Blob.find(@blob.id)
      CdnInvalidation.mark_publicly_cached(@blob)

      stale.update!(metadata: stale.metadata.merge("analyzed" => true, "width" => 10))

      assert CdnInvalidation.publicly_cached?(@blob.reload)
    end

    test "purging a blob invalidates its cached copy and drops its flags" do
      CdnInvalidation.mark_publicly_cached(@blob)
      PublicAssetAllowlist.publish!([ @blob.signed_id ])

      recorded = with_distribution { recorded_invalidations { @blob.purge } }

      assert_equal [ CdnInvalidation.blob_paths(@blob) ], recorded
      assert_not BlobAccessFlag.exists?(blob_id: @blob.id)
    end

    test "does nothing for blobs CloudFront never cached" do
      recorded = with_distribution do
        recorded_invalidations do
          CdnInvalidation.invalidate_blob(@blob)
          CdnInvalidation.invalidate_blob(nil)
        end
      end

      assert_empty recorded
    end

    test "does nothing without a configured distribution" do
      CdnInvalidation.mark_publicly_cached(@blob)

      recorded = with_distribution(nil) do
        assert_not CdnInvalidation.enabled?
        recorded_invalidations { CdnInvalidation.invalidate_blob(@blob) }
      end

      assert_empty recorded
    end

    test "invalidates the blob path of a publicly cached blob" do
      CdnInvalidation.mark_publicly_cached(@blob)

      recorded = with_distribution { recorded_invalidations { CdnInvalidation.invalidate_blob(@blob) } }

      assert_equal [ [ "/public-assets/blobs/#{@blob.signed_id}/*" ] ], recorded
    end

    test "purging a publicly cached blob invalidates it" do
      CdnInvalidation.mark_publicly_cached(@blob)
      path = "/public-assets/blobs/#{@blob.signed_id}/*"

      recorded = with_distribution do
        recorded_invalidations do
          @blob.purge
          @blob.run_callbacks(:commit)
        end
      end

      assert_includes recorded, [ path ]
    end

    test "detaching a publicly cached blob from a creative invalidates it" do
      # An attachment name without a reflection has no dependent purge, so only
      # the attachment hook (not the blob purge hook) can fire here.
      attachment = ActiveStorage::Attachment.create!(name: "detached_probe", record: @creative, blob: @blob)
      CdnInvalidation.mark_publicly_cached(@blob)

      recorded = with_distribution do
        recorded_invalidations do
          attachment.destroy!
          attachment.run_callbacks(:commit)
        end
      end

      assert_equal [ [ "/public-assets/blobs/#{@blob.signed_id}/*" ] ], recorded
      assert ActiveStorage::Blob.exists?(@blob.id)
    end

    test "detaching a description attachment still referenced elsewhere invalidates it" do
      # Description reconciliation detaches with attachment.delete (no destroy
      # callbacks) and keeps a blob another creative still embeds, so neither
      # the attachment nor the purge hook can fire.
      @creative.files.attach(@blob)
      Creative.create!(description: "<p>#{@blob.signed_id}</p>", user: @owner)
      CdnInvalidation.mark_publicly_cached(@blob)
      attachment = @creative.files.attachments.first

      recorded = with_distribution do
        recorded_invalidations { @creative.send(:detach_and_maybe_purge, attachment) }
      end

      assert_equal [ [ "/public-assets/blobs/#{@blob.signed_id}/*" ] ], recorded
      assert ActiveStorage::Blob.exists?(@blob.id)
    end

    test "purging a comment image still attached elsewhere invalidates it" do
      # Attachment#purge deletes the row (no destroy hook) and the blob purge
      # is a no-op while the cross-posted copy keeps it, as in remove_image.
      image = ActiveStorage::Blob.create_and_upload!(io: StringIO.new("x"), filename: "p.png", content_type: "image/png")
      public_post = Comment.create!(creative: @creative, user: @owner, content: "public")
      private_copy = Comment.create!(creative: @creative, user: @owner, content: "inbox", private: true)
      public_post.images.attach(image)
      private_copy.images.attach(image)
      CdnInvalidation.mark_publicly_cached(image)
      path = [ "/public-assets/blobs/#{image.signed_id}/*" ]

      recorded = with_distribution do
        recorded_invalidations { public_post.images.attachments.first.purge }
      end

      assert_equal [ path ], recorded
      assert ActiveStorage::Blob.exists?(image.id)
      assert_equal [ image.id ], private_copy.reload.images.blobs.pluck(:id)
    end

    test "a comment made private or moved invalidates its cached images; other edits do not" do
      image = ActiveStorage::Blob.create_and_upload!(io: StringIO.new("x"), filename: "p.png", content_type: "image/png")
      comment = Comment.create!(creative: @creative, user: @owner, content: "hi")
      comment.images.attach(image)
      CdnInvalidation.mark_publicly_cached(image)
      path = [ "/public-assets/blobs/#{image.signed_id}/*" ]
      other = Creative.create!(description: "<p>other</p>", user: @owner)

      recorded = with_distribution do
        recorded_invalidations do
          comment.update!(content: "edited")
          comment.update!(private: true)
          comment.update!(private: false)
          comment.update_columns(creative_id: other.id)
          comment.reload.update!(creative: @creative)
        end
      end

      assert_equal [ path, path, path ], recorded
    end

    test "moving a topic invalidates the cached images of its comments" do
      image = ActiveStorage::Blob.create_and_upload!(io: StringIO.new("x"), filename: "p.png", content_type: "image/png")
      uncached = ActiveStorage::Blob.create_and_upload!(io: StringIO.new("y"), filename: "q.png", content_type: "image/png")
      topic = @creative.topics.create!(name: "Moving", user: @owner)
      moved = Comment.create!(creative: @creative, topic: topic, user: @owner, content: "hi")
      moved.images.attach(image)
      moved.images.attach(uncached)
      staying = Comment.create!(creative: @creative, user: @owner, content: "stay")
      other_image = ActiveStorage::Blob.create_and_upload!(io: StringIO.new("z"), filename: "r.png", content_type: "image/png")
      staying.images.attach(other_image)
      [ image, other_image ].each { |blob| CdnInvalidation.mark_publicly_cached(blob) }
      target = Creative.create!(description: "<p>private</p>", user: @owner)

      recorded = with_distribution do
        recorded_invalidations { Topics::TopicMove.new(topic: topic, target_creative: target).call }
      end

      assert_equal [ [ "/public-assets/blobs/#{image.signed_id}/*" ] ], recorded
      assert_equal target.id, moved.reload.creative_id
    end

    def history_change_retaining(blob)
      change_set = CreativeChangeSet.create!(anchor_creative: @creative, anchor_source: "agent_topic", user: @owner,
                                             actor_kind: "agent", origin: "tool", status: "applied")
      change = change_set.creative_changes.create!(creative_id: @creative.id, operation: "update",
                                                   before: { "description" => "<p>a</p>" }, after: { "description" => "<p>b</p>" })
      change.history_file_attachments.create!(name: "history_files", blob: blob)
      change
    end

    test "dropping a stale history reference invalidates the cached blob" do
      # The blob stays attached to the creative, so the purge recheck keeps it.
      @creative.files.attach(@blob)
      change = history_change_retaining(@blob)
      CdnInvalidation.mark_publicly_cached(@blob)

      recorded = with_distribution do
        recorded_invalidations { Creatives::History.retain_snapshot_files!(change) }
      end

      assert_equal [ [ "/public-assets/blobs/#{@blob.signed_id}/*" ] ], recorded
      assert_not change.history_file_attachments.exists?
      assert ActiveStorage::Blob.exists?(@blob.id)
    end

    test "destroying a history change invalidates its cached retained files" do
      @creative.files.attach(@blob)
      change = history_change_retaining(@blob)
      CdnInvalidation.mark_publicly_cached(@blob)

      recorded = with_distribution { recorded_invalidations { change.destroy! } }

      assert_equal [ [ "/public-assets/blobs/#{@blob.signed_id}/*" ] ], recorded
    end

    test "invalidation jobs wait for the surrounding transaction to commit" do
      assert CdnInvalidationJob.enqueue_after_transaction_commit
    end

    test "flushing all public assets enqueues the wildcard" do
      recorded = with_distribution { recorded_invalidations { CdnInvalidation.invalidate_all_public_assets } }

      assert_equal [ [ "/public-assets/*" ] ], recorded
    end
  end
end
