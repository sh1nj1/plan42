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

    test "invalidation jobs wait for the surrounding transaction to commit" do
      assert CdnInvalidationJob.enqueue_after_transaction_commit
    end

    test "flushing all public assets enqueues the wildcard" do
      recorded = with_distribution { recorded_invalidations { CdnInvalidation.invalidate_all_public_assets } }

      assert_equal [ [ "/public-assets/*" ] ], recorded
    end
  end
end
