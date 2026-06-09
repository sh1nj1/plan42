module Collavre
  # Embeds attached-but-unreferenced blobs (legacy MCP/console attaches) into a
  # Creative's description HTML so the switch to "description HTML is the source
  # of truth for creative.files" loses nothing. Idempotent and non-destructive.
  module AttachmentBackfill
    module_function

    def embed_orphans!(creative)
      # Markdown-mode creatives manage their own blob lifecycle through
      # MarkdownConverter (markdown_source <-> description) and are excluded
      # from HTML-derived reconcile (reconcile_description_attachments returns
      # early for them). Appending HTML nodes here would be a no-op for
      # reconcile AND would demote the creative to HTML mode via
      # convert_markdown_to_html, silently discarding data["markdown_source"].
      return if creative.data&.dig("content_type") == "markdown"

      referenced = creative.send(:extract_signed_ids_from_description).to_set
      orphans = creative.files.includes(:blob).reject do |att|
        referenced.include?(att.blob.signed_id)
      end
      return if orphans.empty?

      nodes = orphans.map { |att| creative.attachment_node_html(att.blob) }.join
      # Normal save path: sanitizer keeps the nodes; reconcile is a no-op for
      # these blobs since they are already attached.
      creative.update!(description: "#{creative.description}#{nodes}")
    rescue StandardError => e
      Rails.logger.error("AttachmentBackfill: creative #{creative.id} failed: #{e.message}")
    end
  end
end
