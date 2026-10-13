# frozen_string_literal: true

module Collavre
  # Decides whether a viewer may read an ActiveStorage blob. A signed_id only
  # identifies a blob; it is not a capability. Access derives from the records
  # the blob is attached to:
  #
  #   - Creative#files          -> the creative is readable (origin permission)
  #   - Comment#images          -> the comment's creative is readable and the
  #                                comment is not private to someone else
  #   - CreativeChange history  -> the history entry is visible and a snapshot
  #                                state referencing the blob is visible under
  #                                the permission path recorded with it
  #   - User#avatar             -> always readable
  #
  # A blob attached to nothing yet is readable by its uploader (direct upload
  # before save) or, when it has no recorded uploader (server-created blob
  # before reconcile attaches it), by readers of a creative whose description
  # embeds it. Pass `user: nil` to ask whether the blob is public (readable
  # anonymously), which is the only case /public-assets may cache publicly.
  #
  # Operators can publish a blob explicitly (landing-page media that belongs to
  # no public creative) with the BlobAccessFlag public_asset flag; see
  # `rake collavre:public_assets:publish`.
  class BlobAccess
    UPLOADER_METADATA_KEY = "uploaded_by_id"

    # Attaching a blob to a record makes it readable through that record, so a
    # record may only adopt blobs its author can already read, or a fresh
    # server-created blob (no uploader, attached nowhere) that has no owner yet.
    def self.adoptable?(blob, user:)
      return true if new(blob, user: user).readable?

      blob.metadata[UPLOADER_METADATA_KEY].blank? && !ActiveStorage::Attachment.exists?(blob_id: blob.id)
    end

    # The subset of `blobs` the request user (or, outside a request, `owner`)
    # may adopt; refusals are logged.
    def self.adoptable(blobs, owner: nil)
      user = Collavre::Current.user || owner
      blobs.select do |blob|
        adoptable?(blob, user: user).tap do |ok|
          Rails.logger.warn("BlobAccess: refused to attach unreadable blob #{blob.id}") unless ok
        end
      end
    end

    def initialize(blob, user:)
      @blob = blob
      @user = user
    end

    def readable?
      return true if Collavre::BlobAccessFlag.set?(blob.id, :public_asset)

      attachments = ActiveStorage::Attachment.where(blob_id: blob.id).to_a
      return unattached_readable? if attachments.empty?

      return true if attachments.any? { |attachment| avatar?(attachment) }

      creative_ids = attachments.flat_map { |attachment| creative_ids_for(attachment) }
      readable_creative?(creative_ids) || attachments.any? { |attachment| history_readable?(attachment) }
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

    # A retained file is only as visible as the history that keeps it: the
    # change itself (live creative, actor-only for a hard delete, parent for a
    # draft create) and a snapshot state that references the file, judged by
    # the permission path recorded with that snapshot rather than the
    # creative's current placement.
    def history_readable?(attachment)
      return false unless attachment.record_type == Collavre::CreativeChange.name

      change = Collavre::CreativeChange.includes(:change_set).find_by(id: attachment.record_id)
      return false unless change && history_visibility.changes([ change ]).any?

      %w[before after].any? do |state|
        references_blob?(change.public_send(state)) &&
          history_visibility.historical_snapshots_visible?([ change ], state)
      end
    end

    def references_blob?(snapshot)
      signed_ids = %w[description markdown_source].flat_map do |key|
        Collavre::Creatives::History.extract_signed_ids(snapshot[key])
      end
      signed_ids.any? { |signed_id| signed_blob_id(signed_id) == blob.id }
    end

    def signed_blob_id(signed_id)
      ActiveStorage::Blob.find_signed(signed_id)&.id
    rescue ActiveSupport::MessageVerifier::InvalidSignature, ActiveRecord::RecordNotFound
      nil
    end

    def history_visibility
      @history_visibility ||= Collavre::Creatives::ChangeSetVisibility.new(user: user)
    end

    # An uploader-tagged blob stays private to its uploader until it is
    # attached; otherwise anyone could grant themselves access by embedding a
    # leaked signed id in their own creative.
    def unattached_readable?
      uploader_id = blob.metadata[UPLOADER_METADATA_KEY]
      return user.present? && uploader_id.to_s == user.id.to_s if uploader_id.present?

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
