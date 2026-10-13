# frozen_string_literal: true

require "test_helper"

module Collavre
  # A signed blob id identifies a blob but is not a capability: referencing it
  # from a creative or comment must not grant access to someone else's blob.
  class BlobAdoptionTest < ActionDispatch::IntegrationTest
    PNG = File.binread(Collavre::Engine.root.join("test/fixtures/files/small.png"))

    setup do
      @owner = users(:one)
      @stranger = users(:three)
      Current.user = @owner
      @private = Creative.create!(description: "<p>private</p>", user: @owner)
      @secret = upload
      @private.files.attach(@secret)
    end

    teardown { Current.reset }

    # Each request starts with a fresh Current (and so a fresh history change set).
    def act_as(user)
      Current.reset
      Current.user = user
    end

    def upload(metadata = {})
      ActiveStorage::Blob.create_and_upload!(io: StringIO.new(PNG), filename: "small.png", content_type: "image/png", metadata: metadata)
    end

    def embed(blob)
      %(<p><img src="/public-assets/blobs/#{blob.signed_id}/small.png"></p>)
    end

    def readable?(blob, user)
      BlobAccess.new(blob, user: user).readable?
    end

    test "a creative cannot adopt a blob its editor cannot read" do
      act_as(@stranger)
      mine = Creative.create!(description: embed(@secret), user: @stranger)

      assert_not mine.files.attachments.exists?(blob_id: @secret.id)
      assert_not ActiveStorage::Attachment.exists?(blob_id: @secret.id, name: "history_files")
      assert_not readable?(@secret, @stranger)
    end

    test "an unattached upload stays private to its uploader even when embedded elsewhere" do
      draft = upload(BlobAccess::UPLOADER_METADATA_KEY => @owner.id.to_s)
      act_as(@stranger)
      mine = Creative.create!(description: embed(draft), user: @stranger)

      assert_not mine.files.attachments.exists?(blob_id: draft.id)
      assert_not readable?(draft, @stranger)
      assert readable?(draft, @owner)
    end

    test "an editor may reuse a blob they can read" do
      copy = Creative.create!(description: embed(@secret), user: @owner)

      assert copy.files.attachments.exists?(blob_id: @secret.id)
    end

    test "own uploads and server-created blobs are adopted, falling back to the owner without a request user" do
      own = upload(BlobAccess::UPLOADER_METADATA_KEY => @owner.id.to_s)
      server = upload
      act_as(nil)
      creative = Creative.create!(description: embed(own) + embed(server), user: @owner)

      assert_equal [ own.id, server.id ].sort, creative.files.attachments.pluck(:blob_id).sort
    end

    test "a comment cannot attach someone else's blob by signed id" do
      target = Creative.create!(description: "<p>mine</p>", user: @stranger)
      sign_in_as(@stranger, password: "password")

      assert_no_difference -> { Comment.count } do
        post collavre.creative_comments_path(target), params: { comment: { content: "hi", images: [ @secret.signed_id ] } }
      end
      assert_response :forbidden
      assert_not readable?(@secret, @stranger)
    end

    test "a comment may attach the commenter's own upload" do
      target = Creative.create!(description: "<p>mine</p>", user: @stranger)
      own = upload(BlobAccess::UPLOADER_METADATA_KEY => @stranger.id.to_s)
      sign_in_as(@stranger, password: "password")

      assert_difference -> { Comment.count }, 1 do
        post collavre.creative_comments_path(target), params: { comment: { content: "hi", images: [ own.signed_id ] } }
      end
      assert_response :created
      assert_equal [ own.id ], Comment.last.images.blobs.pluck(:id)
    end

    test "a comment update cannot attach someone else's blob by signed id" do
      target = Creative.create!(description: "<p>mine</p>", user: @stranger)
      comment = Comment.create!(creative: target, user: @stranger, content: "hi")
      sign_in_as(@stranger, password: "password")

      patch collavre.creative_comment_path(target, comment), params: { comment: { content: "hi", images: [ @secret.signed_id ] } }

      assert_response :forbidden
      assert_not comment.reload.images.attached?
      assert_not readable?(@secret, @stranger)
    end

    test "an avatar cannot adopt someone else's blob by signed id" do
      sign_in_as(@stranger, password: "password")

      patch collavre.user_path(@stranger), params: { user: { avatar: @secret.signed_id } }

      assert_response :forbidden
      assert_not @stranger.reload.avatar.attached?
      assert_not readable?(@secret, @stranger)
      assert_not readable?(@secret, nil)
    end

    test "an avatar may use the user's own upload" do
      own = upload(BlobAccess::UPLOADER_METADATA_KEY => @stranger.id.to_s)
      sign_in_as(@stranger, password: "password")

      patch collavre.user_path(@stranger), params: { user: { avatar: own.signed_id } }

      assert_redirected_to collavre.user_path(@stranger)
      assert_equal own.id, @stranger.reload.avatar.blob.id
    end
  end
end
