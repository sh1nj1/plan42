module Collavre
  class Creative < ApplicationRecord
    module Describable
      extend ActiveSupport::Concern

      included do
        validates :description, presence: true, unless: -> { origin_id.present? }
        validate :description_cannot_change_if_has_origin, on: :update
        validate :description_cannot_change_if_github_source, on: :update

        before_save :sanitize_description_html
        after_destroy_commit :purge_description_attachments
      end

      # Linked Creative의 description을 안전하게 반환
      def effective_description(variation_id = nil, html = true)
        if variation_id.present?
          variation_tag = tags.find_by(label_id: variation_id)
          return variation_tag.value if variation_tag&.value.present?
        end
        description_val = origin_id.nil? ? description : origin.description
        if html
          description_val&.to_s || ""
        else
          ActionController::Base.helpers.strip_tags(description_val&.to_s || "")
        end
      end

      def creative_snippet
        CGI.unescapeHTML(ActionController::Base.helpers.strip_tags(effective_origin.description || "")).truncate(24, omission: "...")
      end

      private

      def sanitize_description_html
        table_tags = %w[table thead tbody tfoot tr th td]
        table_attrs = %w[colspan rowspan]
        attachment_attrs = %w[download data-filesize]
        self.description = ActionController::Base.helpers.sanitize(
          description,
          tags: Rails::HTML5::SafeListSanitizer.allowed_tags.to_a + table_tags,
          attributes: Rails::HTML5::SafeListSanitizer.allowed_attributes.to_a + table_attrs + attachment_attrs + %w[data-lexical]
        )
      end

      def purge_description_attachments
        return if description.blank?

        signed_ids = extract_signed_ids_from_description
        return if signed_ids.empty?

        signed_ids.each do |signed_id|
          begin
            blob = ActiveStorage::Blob.find_signed(signed_id)
            next unless blob

            next if Creative.where.not(id: id)
                            .where("description LIKE ?", "%#{ActiveRecord::Base.sanitize_sql_like(signed_id)}%")
                            .exists?

            blob.purge
          rescue ActiveRecord::RecordNotFound, ActiveSupport::MessageVerifier::InvalidSignature
            Rails.logger.warn("Creative##{id}: could not find blob for signed_id=#{signed_id}")
          rescue StandardError => e
            Rails.logger.error("Creative##{id}: failed to purge blob #{signed_id}: #{e.message}")
          end
        end
      end

      def extract_signed_ids_from_description
        return [] if description.blank?

        html = description.to_s

        ids = html.scan(%r{/rails/active_storage/blobs/(?:redirect|proxy)/([^/?#]+)}).flatten
        ids += html.scan(%r{/rails/active_storage/blobs/([^/?#]+)}).flatten

        ids.uniq
      end

      def description_cannot_change_if_has_origin
        if origin_id.present? && will_save_change_to_description?
          errors.add(:description, "cannot be changed directly when linked to an origin")
        end
      end

      def description_cannot_change_if_github_source
        return unless will_save_change_to_description?
        return unless data.is_a?(Hash) && data.dig("source", "type") == "github_markdown"
        # Allow changes from the sync context (set via Collavre::Current)
        return if defined?(Collavre::Current) && Collavre::Current.respond_to?(:markdown_sync?) && Collavre::Current.markdown_sync?

        errors.add(:description, "cannot be changed directly for GitHub synced content")
      end
    end
  end
end
