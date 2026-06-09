module Collavre
  class Creative < ApplicationRecord
    module Describable
      extend ActiveSupport::Concern

      included do
        attr_accessor :content_type_input
        attr_reader :markdown_source

        def markdown_source=(value)
          @markdown_source = value.is_a?(String) ? value.gsub(/\r\n?/, "\n") : value
        end

        validates :description, presence: true, unless: -> { origin_id.present? }
        validate :description_cannot_change_if_has_origin, on: :update
        validate :description_cannot_change_if_github_source, on: :update

        before_validation :convert_markdown_to_html
        before_save :sanitize_description_html
        after_save :reconcile_description_attachments
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

      # Append an attachment node for `blob` to the description and save.
      # after_save reconcile then attaches the blob to creative.files.
      def embed_attachment_blob!(blob)
        node = attachment_node_html(blob)
        new_html = "#{description}#{node}"
        # Markdown-mode creatives derive description from markdown_source; demote
        # to HTML so the embedded node is the persisted source of truth.
        self.content_type_input = "html" if data&.dig("content_type") == "markdown"
        update!(description: new_html)
      end

      # HTML for embedding a blob inline, branching on content type. The proxy
      # path MUST match what extract_signed_ids_from_description scans and what
      # the sanitizer allows.
      def attachment_node_html(blob)
        url = "/public-assets/blobs/#{blob.signed_id}/#{blob.filename.sanitized}"
        name = ERB::Util.html_escape(blob.filename.to_s)
        if blob.content_type.to_s.start_with?("image/")
          %(<img src="#{url}" alt="#{name}">)
        elsif blob.content_type.to_s.start_with?("video/")
          %(<video controls src="#{url}"></video>)
        else
          %(<a href="#{url}" download="#{name}" data-filesize="#{blob.byte_size}">#{name}</a>)
        end
      end

      private

      def convert_markdown_to_html
        if content_type_input == "markdown"
          self.data ||= {}
          new_source = markdown_source.to_s
          prev_source = data["markdown_source"].to_s
          prev_type = data["content_type"]
          self.data["content_type"] = "markdown"
          if new_source != prev_source || prev_type != "markdown"
            # Rewrite inline data-URI images to freshly-uploaded blob paths
            # FIRST, then persist the rewritten source. Subsequent edits
            # around the same image carry the blob path instead of the
            # data URI, so re-renders no longer create duplicate blobs.
            rewritten_source = Collavre::MarkdownConverter.rewrite_data_uri_images(new_source)
            self.data["markdown_source"] = rewritten_source
            self.description = Collavre::MarkdownConverter.markdown_to_html(rewritten_source)
          else
            self.data["markdown_source"] = new_source
            # Source unchanged: description must stay derived from markdown_source.
            # Restore the persisted value rather than trusting params[:description],
            # which would let a stale/crafted request diverge from markdown_source.
            # Skipping the re-render also avoids re-importing data-URI images as
            # fresh Active Storage blobs on every autosave/progress/move.
            self.description = description_was if description_changed?
          end
        elsif content_type_input == "html"
          self.data ||= {}
          self.data.delete("content_type")
          self.data.delete("markdown_source")
        elsif !new_record? && description_changed? && data&.dig("content_type") == "markdown"
          # Description was rewritten through a non-markdown path (tool/MCP
          # update, direct base.update(description: ...), etc.) on a creative
          # that was previously in markdown mode. The new HTML no longer
          # matches data["markdown_source"], so the next inline-markdown open
          # would load the stale source and silently overwrite this update.
          # Demote to HTML mode so the persisted source matches description.
          self.data.delete("content_type")
          self.data.delete("markdown_source")
        end
      end

      def sanitize_description_html
        table_tags = %w[table thead tbody tfoot tr th td]
        table_attrs = %w[colspan rowspan]
        attachment_attrs = %w[download data-filesize]
        task_list_attrs = %w[type disabled checked]
        media_tags = %w[video source]
        media_attrs = %w[controls src preload width height poster]

        # GFM task list checkboxes (`- [ ]` / `- [x]`) render as
        # <input type="checkbox" disabled> via Commonmarker's tasklist
        # extension. Strip any other <input> variant before sanitization
        # so allowing the `input` tag in the safelist can't smuggle in
        # text/image/submit inputs.
        scrubbed = Loofah.fragment(description.to_s)
        scrubbed.css("input").each do |node|
          unless node["type"] == "checkbox" && node.has_attribute?("disabled")
            node.remove
          end
        end

        self.description = ActionController::Base.helpers.sanitize(
          scrubbed.to_html,
          tags: Rails::HTML5::SafeListSanitizer.allowed_tags.to_a + table_tags + media_tags + %w[input],
          attributes: Rails::HTML5::SafeListSanitizer.allowed_attributes.to_a + table_attrs + attachment_attrs + task_list_attrs + media_attrs + %w[data-lexical]
        )
      end

      # Description HTML is the source of truth for attachments. After each save,
      # make creative.files exactly match the blobs referenced in the description:
      # attach referenced-but-unattached blobs, detach attached-but-unreferenced.
      # Must never raise during save — malformed HTML yields [] and a no-op.
      #
      # Markdown-mode creatives manage their own blob lifecycle through
      # MarkdownConverter (markdown_source <-> description) and
      # purge_description_attachments; HTML-derived reconcile would fight that.
      # The embed paths (embed_attachment_blob!) demote markdown -> html first,
      # so agent/editor uploads are still reconciled.
      def reconcile_description_attachments
        return if data&.dig("content_type") == "markdown"

        referenced = extract_signed_ids_from_description.filter_map do |sid|
          ActiveStorage::Blob.find_signed(sid)
        rescue ActiveSupport::MessageVerifier::InvalidSignature, ActiveRecord::RecordNotFound
          nil
        end
        referenced_ids = referenced.map(&:id).to_set

        current = files.includes(:blob).to_a
        current_blob_ids = current.map(&:blob_id).to_set

        to_attach = referenced.reject { |b| current_blob_ids.include?(b.id) }
        to_detach = current.reject { |a| referenced_ids.include?(a.blob_id) }
        return if to_attach.empty? && to_detach.empty?

        to_attach.each { |blob| files.attach(blob) }
        to_detach.each(&:purge_later)
      rescue StandardError => e
        Rails.logger.error("Creative##{id}: reconcile_description_attachments failed: #{e.message}")
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
        ids += html.scan(%r{/public-assets/blobs/([^/?#]+)}).flatten

        ids.uniq
      end

      def description_cannot_change_if_has_origin
        if origin_id.present? && will_save_change_to_description?
          errors.add(:description, "cannot be changed directly when linked to an origin")
        end
      end

      def description_cannot_change_if_github_source
        return unless will_save_change_to_description?
        return unless github_markdown?
        return if @skip_github_validation

        errors.add(:description, "cannot be changed directly for GitHub synced content")
      end
    end
  end
end
