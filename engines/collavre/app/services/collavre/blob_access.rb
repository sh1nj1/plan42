# frozen_string_literal: true

module Collavre
  # Decides whether a viewer may read an ActiveStorage blob. A signed_id only
  # identifies a blob; it is not a capability. Access derives from the records
  # the blob is attached to:
  #
  #   - Creative#files          -> the creative is readable (origin permission)
  #   - Comment#images          -> the comment's creative is readable and the
  #                                comment is not private to someone else
  #   - CreativeChange history  -> the changed (or anchor) creative is readable
  #   - User#avatar             -> always readable
  #
  # A blob attached to nothing yet (direct upload before save, draft embed) is
  # readable by its uploader or by readers of a creative whose description
  # embeds it. Pass `user: nil` to ask whether the blob is public (readable
  # anonymously), which is the only case /public-assets may cache publicly.
  #
  # Operators can publish a blob explicitly (landing-page media that belongs to
  # no public creative) with the PUBLIC_METADATA_KEY flag; see
  # `rake collavre:public_assets:publish`.
  class BlobAccess
    UPLOADER_METADATA_KEY = "uploaded_by_id"
    PUBLIC_METADATA_KEY = "public_asset"

    def initialize(blob, user:)
      @blob = blob
      @user = user
    end

    def readable?
      return true if blob.metadata[PUBLIC_METADATA_KEY] == true

      attachments = ActiveStorage::Attachment.where(blob_id: blob.id).to_a
      return unattached_readable? if attachments.empty?

      return true if attachments.any? { |attachment| avatar?(attachment) }

      creative_ids = attachments.flat_map { |attachment| creative_ids_for(attachment) }
      readable_creative?(creative_ids)
    end

    private

    attr_reader :blob, :user

    def avatar?(attachment)
      attachment.name == "avatar" && attachment.record_type == Collavre.user_class.name
    end

    def creative_ids_for(attachment)
      case attachment.record_type
      when Collavre::Creative.name
        [ attachment.record_id ]
      when Collavre::Comment.name
        comment_creative_ids(attachment.record_id)
      when Collavre::CreativeChange.name
        change_creative_ids(attachment.record_id)
      else
        []
      end
    end

    def comment_creative_ids(comment_id)
      comment = Collavre::Comment.find_by(id: comment_id)
      return [] unless comment
      return [] if comment.private? && !comment_participant?(comment)

      [ comment.creative_id ]
    end

    def comment_participant?(comment)
      user.present? && [ comment.user_id, comment.approver_id ].include?(user.id)
    end

    # A draft create has a negative placeholder creative_id until approval, so
    # fall back to the change set's anchor creative.
    def change_creative_ids(change_id)
      change = Collavre::CreativeChange.includes(:change_set).find_by(id: change_id)
      return [] unless change

      [ change.creative_id, change.change_set&.anchor_creative_id ].compact.select(&:positive?)
    end

    def unattached_readable?
      return true if user && blob.metadata[UPLOADER_METADATA_KEY].to_s == user.id.to_s

      pattern = "%#{ActiveRecord::Base.sanitize_sql_like(blob.signed_id)}%"
      readable_creative?(Collavre::Creative.where("description LIKE ?", pattern).pluck(:id))
    end

    def readable_creative?(creative_ids)
      creative_ids = creative_ids.compact.uniq
      return false if creative_ids.empty?

      Collavre::Creatives::PermissionFilter.new(user: user).readable_ids(creative_ids).any?
    end
  end
end
