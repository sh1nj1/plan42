module Collavre
  class Creative < ApplicationRecord
    module Describable
      extend ActiveSupport::Concern

      included do
        attr_accessor :content_type_input
        # Which editing surface authored this Markdown: "rich" (Lexical) reopens
        # in the rich editor, "source" (or absent/legacy) reopens in the advanced
        # textarea. Stored in data["editor"]; decoupled from the storage format
        # (content_type), which is now Markdown for both surfaces.
        attr_accessor :markdown_editor
        # When true, convert_markdown_to_html stores markdown_source verbatim
        # instead of rewriting inline data-URI images into Active Storage blobs.
        # Used by prompt sync, where markdown_source is the canonical text sent
        # to the LLM and must stay byte-for-byte what the user entered.
        attr_accessor :skip_data_uri_rewrite
        attr_reader :markdown_source

        def markdown_source=(value)
          @markdown_source = value.is_a?(String) ? value.gsub(/\r\n?/, "\n") : value
        end

        validates :description, presence: true, unless: -> { origin_id.present? }
        validate :description_cannot_change_if_has_origin, on: :update
        validate :description_cannot_change_if_read_only_source, on: :update

        before_validation :convert_markdown_to_html
        before_save :sanitize_description_html
        after_save :reconcile_description_attachments
        after_destroy_commit :purge_description_attachments
      end

      # Linked Creative의 description을 안전하게 반환
      def effective_description(variation_id = nil, html = true)
        if variation_id.present?
          # `find_by` on a loaded association still round-trips; the browse tree
          # preloads tags per level and reaches here once per node.
          variation_tag = if tags.loaded?
            tags.find { |tag| tag.label_id.to_s == variation_id.to_s }
          else
            tags.find_by(label_id: variation_id)
          end
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

      # Read-only-source creatives reject any description change
      # (description_cannot_change_if_read_only_source), so embedding would raise
      # and orphan the blob. Callers MUST check this before creating the blob.
      def attachments_embeddable?
        !effective_origin.read_only_source?
      end

      # Append an attachment node and save; after_save reconcile attaches the
      # blob to creative.files. Linked creatives can't change their own
      # description (it lives on the origin), so embed on effective_origin —
      # otherwise the save raises and orphans the blob.
      def embed_attachment_blob!(blob)
        target = effective_origin
        return target.embed_attachment_blob!(blob) unless target == self

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

      # Remove the attachment for `signed_id`. HTML is the source of truth, so
      # strip the node and let after_save reconcile detach + safe-purge. A blob
      # that's attached but not embedded (legacy, not yet backfilled) is
      # detached directly. Returns true if an attachment was present.
      def remove_attachment!(signed_id)
        target = effective_origin
        return target.remove_attachment!(signed_id) unless target == self

        blob = ActiveStorage::Blob.find_signed(signed_id)
        return false unless blob

        attachment = files.attachments.find_by(blob_id: blob.id)
        return false unless attachment

        stripped = description_without_attachment_node(blob.signed_id)
        if stripped
          # Demote markdown -> html so the stripped HTML is the persisted source
          # of truth (mirrors embed_attachment_blob!).
          self.content_type_input = "html" if data&.dig("content_type") == "markdown"
          update!(description: stripped)
        else
          detach_and_maybe_purge(attachment)
        end
        true
      end

      private

      # description HTML with every node (<img>/<video>/<source>/<a>) whose
      # src/href references signed_id removed, or nil when none is present.
      def description_without_attachment_node(signed_id)
        return nil if description.blank?

        doc = Loofah.fragment(description.to_s)
        matches = doc.css("img, video, source, a").select do |node|
          ref = node["src"] || node["href"]
          ref&.include?(signed_id)
        end
        return nil if matches.empty?

        matches.each(&:remove)
        doc.to_html
      end

      def convert_markdown_to_html
        if content_type_input == "markdown"
          self.data ||= {}
          new_source = markdown_source.to_s
          prev_source = data["markdown_source"].to_s
          prev_type = data["content_type"]
          self.data["content_type"] = "markdown"
          # Remember which surface authored this. Absent param (MCP/tool writes)
          # keeps the prior choice, defaulting to the advanced textarea.
          self.data["editor"] = markdown_editor.presence || data["editor"] || "source"
          if new_source != prev_source || prev_type != "markdown"
            # Rewrite inline data-URI images to freshly-uploaded blob paths
            # FIRST, then persist the rewritten source. Subsequent edits
            # around the same image carry the blob path instead of the
            # data URI, so re-renders no longer create duplicate blobs.
            # skip_data_uri_rewrite callers (prompt sync) keep the source
            # verbatim; the derived HTML still renders the data URI inline.
            # Profile creatives are agent prompts: markdown_source is sent
            # verbatim to the LLM, so the rewrite must never fire for them
            # regardless of caller — a direct Creative-editor edit reaches this
            # path without the skip flag, but its source is equally LLM-bound.
            rewritten_source = if skip_data_uri_rewrite || data["kind"] == PROFILE_KIND
              new_source
            else
              Collavre::MarkdownConverter.rewrite_data_uri_images(new_source)
            end
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
          self.data.delete("editor")
        elsif !new_record? && description_changed? && data&.dig("content_type") == "markdown"
          # Description was rewritten through a non-markdown path (tool/MCP
          # update, direct base.update(description: ...), etc.) on a creative
          # that was previously in markdown mode. The new HTML no longer
          # matches data["markdown_source"], so the next inline-markdown open
          # would load the stale source and silently overwrite this update.
          # Demote to HTML mode so the persisted source matches description.
          self.data.delete("content_type")
          self.data.delete("markdown_source")
          self.data.delete("editor")
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

        # The Lexical editor stores text color / background as inline <span
        # style="...">. Tighten every style attribute to ONLY validated color /
        # background-color declarations BEFORE sanitization, so allowing `style`
        # in the safelist can't smuggle layout/position/url() payloads.
        scrub_inline_color_styles(scrubbed)

        self.description = ActionController::Base.helpers.sanitize(
          scrubbed.to_html,
          tags: Rails::HTML5::SafeListSanitizer.allowed_tags.to_a + table_tags + media_tags + %w[input],
          attributes: Rails::HTML5::SafeListSanitizer.allowed_attributes.to_a + table_attrs + attachment_attrs + task_list_attrs + media_attrs + %w[data-lexical style]
        )
      end

      # Only these CSS color values may appear in a stored inline style — mirrors
      # the JS markdown serializer's allowlist (markdown_serialize.js). Blocks
      # url(), expression(), javascript:, and angle brackets.
      SAFE_COLOR_VALUE = /\A(#[0-9a-fA-F]{3,8}|rgba?\([0-9.,%\s]+\)|hsla?\([0-9.,%\s]+\)|var\(--[a-zA-Z0-9\-_]+\)|[a-zA-Z]+)\z/

      def scrub_inline_color_styles(fragment)
        fragment.css("[style]").each do |node|
          declarations = node["style"].to_s.split(";").filter_map do |decl|
            key, value = decl.split(":", 2)
            next if key.nil? || value.nil?

            key = key.strip.downcase
            value = value.strip
            next unless %w[color background-color].include?(key)
            next if value =~ /url\(|expression|javascript:|@import|[<>]/i
            next unless value =~ SAFE_COLOR_VALUE

            "#{key}: #{value}"
          end

          if declarations.any?
            node["style"] = declarations.join("; ")
          else
            node.remove_attribute("style")
          end
        end
      end

      # Sync creative.files to the blobs referenced in the description HTML
      # (attach new, detach removed). Must never raise during save — malformed
      # HTML yields [] and a no-op.
      #
      # The rich (Lexical) editor is now Markdown-canonical and serializes
      # inserted images/videos/files as raw blob-URL tags inside markdown_source,
      # which markdown_to_html renders into `description`. So reconcile must run
      # for markdown mode too, otherwise rich-editor uploads never reach
      # creative.files (and the attachment list/remove services miss them).
      #
      # Markdown detach is narrowed (not skipped): markdown creatives may carry
      # legacy blobs attached directly but never embedded in the derived
      # description (AttachmentBackfill skips markdown, so reconcile is their only
      # touch point) — those must survive. But media the user actually removed
      # in-editor WAS referenced in the prior description and no longer is; that
      # must detach, or creative.files keeps listing a deleted file (the editor's
      # purge DELETE can't compensate while the attachment still exists). So for
      # markdown we detach only blobs that were previously referenced. HTML keeps
      # full detach (backfill embeds its orphans, so none should linger).
      def reconcile_description_attachments
        # Linked creatives don't own their description (it lives on the origin)
        # and their own column is blank, so reconcile would treat every legacy
        # attachment as an orphan and purge it on the next save (e.g. a
        # reparent). Skip them to preserve pre-existing linked-row attachments.
        return if origin_id.present?

        referenced = extract_signed_ids_from_description.filter_map do |sid|
          ActiveStorage::Blob.find_signed(sid)
        rescue ActiveSupport::MessageVerifier::InvalidSignature, ActiveRecord::RecordNotFound
          nil
        end
        referenced_ids = referenced.map(&:id).to_set

        current = files.includes(:blob).to_a
        current_blob_ids = current.map(&:blob_id).to_set

        markdown = data&.dig("content_type") == "markdown"
        to_attach = referenced.reject { |b| current_blob_ids.include?(b.id) }
        unreferenced = current.reject { |a| referenced_ids.include?(a.blob_id) }
        to_detach =
          if markdown
            prev_referenced_ids = blob_ids_referenced_in(description_before_last_save)
            unreferenced.select { |a| prev_referenced_ids.include?(a.blob_id) }
          else
            unreferenced
          end
        return if to_attach.empty? && to_detach.empty?

        to_attach.each { |blob| files.attach(blob) }
        to_detach.each { |attachment| detach_and_maybe_purge(attachment) }
      rescue StandardError => e
        Rails.logger.error("Creative##{id}: reconcile_description_attachments failed: #{e.message}")
      end

      # Detach this creative's join, then purge the blob ONLY if nothing else
      # references it — a shared blob (description copied between creatives)
      # would otherwise be deleted out from under the others, 404-ing their
      # descriptions.
      def detach_and_maybe_purge(attachment)
        blob = attachment.blob
        attachment.delete
        return if blob.nil?

        signed_id = blob.signed_id
        still_referenced = Creative.where.not(id: id)
                                   .where("description LIKE ?", "%#{ActiveRecord::Base.sanitize_sql_like(signed_id)}%")
                                   .exists?
        return if still_referenced
        return if ActiveStorage::Attachment.where(blob_id: blob.id).exists?

        blob.purge_later
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
        extract_signed_ids_from(description)
      end

      def extract_signed_ids_from(html)
        return [] if html.blank?

        html = html.to_s

        ids = html.scan(%r{/rails/active_storage/blobs/(?:redirect|proxy)/([^/?#]+)}).flatten
        ids += html.scan(%r{/rails/active_storage/blobs/([^/?#]+)}).flatten
        ids += html.scan(%r{/public-assets/blobs/([^/?#]+)}).flatten

        ids.uniq
      end

      # Blob ids that `html` references, resolving each signed id to its blob.
      # Used to tell user-removed media (was referenced, now gone) apart from
      # legacy orphans (never referenced) during markdown reconcile.
      def blob_ids_referenced_in(html)
        extract_signed_ids_from(html).filter_map do |sid|
          ActiveStorage::Blob.find_signed(sid)&.id
        rescue ActiveSupport::MessageVerifier::InvalidSignature, ActiveRecord::RecordNotFound
          nil
        end.to_set
      end

      def description_cannot_change_if_has_origin
        if origin_id.present? && will_save_change_to_description?
          errors.add(:description, "cannot be changed directly when linked to an origin")
        end
      end

      def description_cannot_change_if_read_only_source
        return unless will_save_change_to_description?
        return unless read_only_source?
        return if skip_read_only_source_validation

        errors.add(:description, I18n.t("collavre.creatives.errors.description_read_only_source"))
      end
    end
  end
end
