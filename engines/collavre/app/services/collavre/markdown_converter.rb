require "base64"
require "securerandom"
require "nokogiri"
require "commonmarker"

module Collavre
  # Converts between Markdown and HTML for creative descriptions.
  #
  # Extracted from CreativesHelper to keep conversion logic testable
  # outside of view contexts and reusable from services (e.g. MarkdownImporter).
  class MarkdownConverter
    class << self
      # Convert Markdown to HTML using commonmarker (GFM full support).
      # Falls back to lightweight regex conversion for short inline fragments.
      def markdown_to_html(text, image_refs = {})
        return "" if text.nil?

        # Protect fenced code blocks and inline code spans from the regex
        # rewrites below — a Markdown sample like ```` ```md\n![x](data:...)\n``` ````
        # must not silently upload its data URI as an Active Storage blob.
        input = with_code_protected(text.dup) do |source|
          # Collect reference-style data-URI images. CommonMark allows both the
          # angle-bracket form `[alt]: <data:...>` and the bare form
          # `[alt]: data:image/...`, optionally followed by a title.
          source.gsub!(/^\s*\[([^\]]+)\]:\s*(?:<\s*(data:image\/[^>]+?)\s*>|(data:image\/\S+))\s*(?:"[^"]*"|'[^']*'|\([^)]*\))?\s*$/) do
            image_refs[$1] = ($2 || $3).strip
            ""
          end

          # Convert data-URI images to Active Storage before rendering
          source.gsub!(/(?<!\\)!\[([^\]]*)\]\[([^\]]+)\]/) do
            if (data_url = image_refs[$2])
              data_image_to_attachment(data_url, $1)
            else
              "![#{$1}][#{$2}]"
            end
          end

          # Inline data-URI images. base64 contains no whitespace or `)`, so bound
          # the URL on those and capture an optional CommonMark title separately;
          # otherwise `data:...;base64,XYZ "caption"` would be slurped as one URL
          # and fail the strict parser in `data_image_to_attachment`. Titles may be
          # double-quoted, single-quoted, or parenthesized per CommonMark.
          source.gsub!(/(?<!\\)!\[([^\]]*)\]\(\s*(data:image\/[^\s)]+)(?:\s+(?:"[^"]*"|'[^']*'|\([^)]*\)))?\s*\)/) do
            data_image_to_attachment($2, $1)
          end

          source
        end

        # Render with commonmarker (GFM extensions: table, strikethrough, autolink, tasklist, tagfilter)
        html = Commonmarker.to_html(input, options: {
          parse: { smart: true },
          render: { unsafe: true },
          extension: { table: true, strikethrough: true, autolink: true, tasklist: true, tagfilter: true }
        })

        html.strip!
        html
      end

      # Convert HTML (links, bold, images, tables) back to Markdown.
      def html_to_markdown(text)
        return "" if text.nil?
        markdown = text.dup
        placeholders = {}
        index = 0

        # Tables → Markdown tables
        markdown.gsub!(%r{<table\b[^>]*>.*?</table>}im) do |match|
          token = "__TABLE#{index}__"; index += 1
          placeholders[token] = table_to_markdown(match)
          token
        end

        # Action-text attachments → data-URI images
        markdown.gsub!(%r{<action-text-attachment ([^>]+)>(?:</action-text-attachment>)?}) do |_match|
          attrs = Hash[$1.scan(/(\S+?)="([^"]*)"/)]
          sgid = attrs["sgid"]
          caption = attrs["caption"] || ""
          if (blob = GlobalID::Locator.locate_signed(sgid, for: "attachable"))
            data = Base64.strict_encode64(blob.download)
            token = "__IMG#{index}__"; index += 1
            placeholders[token] = "![#{caption}](data:#{blob.content_type};base64,#{data})"
            token
          else
            ""
          end
        end

        # Active Storage blob images → data-URI
        markdown.gsub!(%r{<img [^>]*src=["'](/rails/active_storage/blobs/[^"']+)["'][^>]*alt=["']([^"']*)["'][^>]*>}) do |match|
          blob_path = $1
          alt_text = $2
          if blob_path =~ %r{/rails/active_storage/blobs/(?:redirect|proxy)/([^/]+)/}
            signed_id = $1
            begin
              blob = ActiveStorage::Blob.find_signed(signed_id)
              data = Base64.strict_encode64(blob.download)
              token = "__IMG#{index}__"; index += 1
              placeholders[token] = "![#{alt_text}](data:#{blob.content_type};base64,#{data})"
              token
            rescue StandardError
              match
            end
          else
            match
          end
        end

        # Inline data-URI images (src before alt)
        markdown.gsub!(/<img [^>]*src=['"](data:[^'"]+)['"][^>]*alt=['"]([^'"]*)['"][^>]*>/) do
          token = "__IMG#{index}__"; index += 1
          placeholders[token] = "![#{$2}](#{$1})"
          token
        end

        # Inline data-URI images (alt before src)
        markdown.gsub!(/<img [^>]*alt=['"]([^'"]*)['"][^>]*src=['"](data:[^'"]+)['"][^>]*>/) do
          token = "__IMG#{index}__"; index += 1
          placeholders[token] = "![#{$1}](#{$2})"
          token
        end

        # Links → [text](url)
        markdown.gsub!(/<a [^>]*href=['"]([^'"]+)['"][^>]*>(.*?)<\/a>/m) do
          inner = ActionView::Base.full_sanitizer.sanitize($2)
          token = "__LINK#{index}__"; index += 1
          placeholders[token] = "[#{inner}](#{$1})"
          token
        end

        # Bold → **text**
        markdown.gsub!(/<(strong|b)(?:\s+[^>]*)?>(.*?)<\/\1>/im) do
          token = "__BOLD#{index}__"; index += 1
          placeholders[token] = "**#{$2.strip}**"
          token
        end

        # Escape markdown special chars in remaining text
        markdown.gsub!(/([\\*\[\]()!#~+\-])/) { "\\#{$1}" }

        # Restore placeholders
        placeholders.each { |k, v| markdown.gsub!(k, v) }

        # Strip remaining HTML tags
        markdown.gsub!(/<[^>]+>/, "")
        markdown
      end

      # Check whether text looks like a Markdown table block.
      def table_block?(text)
        lines = text.to_s.strip.split("\n")
        return false if lines.length < 2

        header_line = lines[0]
        alignment_line = lines[1]
        return false unless header_line.match?(/\A\|.*\|\z/)
        return false unless alignment_line.match?(/\A\|[ \-:\|]+\|\z/)

        true
      end

      # Convert an HTML <table> fragment to a Markdown table string.
      def table_to_markdown(table_html)
        fragment = Nokogiri::HTML::DocumentFragment.parse(table_html)
        table = fragment.at_css("table")
        return "" unless table

        header_row = table.at_css("thead tr") || table.css("tr").first
        return "" unless header_row

        header_cells = header_row.css("th,td")
        headers = header_cells.map { |cell| escape_table_cell(html_to_markdown(cell.inner_html).strip) }
        alignments = header_cells.map { |cell| alignment_from_cell(cell) }

        body_rows = table.css("tbody tr")
        if body_rows.empty?
          all_rows = table.css("tr")
          body_rows = all_rows.drop(1)
        end

        body_lines = body_rows.map do |row|
          cells = row.css("th,td").map { |cell| escape_table_cell(html_to_markdown(cell.inner_html).strip) }
          normalized = pad_cells(cells, headers.length)
          "| #{normalized.join(' | ')} |"
        end

        alignment_cells = pad_cells(alignments, headers.length).map { |align| alignment_marker(align) }
        header_line = "| #{headers.map(&:strip).join(' | ')} |"
        alignment_line = "| #{alignment_cells.join(' | ')} |"

        ([ header_line, alignment_line ] + body_lines).join("\n")
      end

      # Convert a data-URI image to an Active Storage attachment <img> tag.
      def data_image_to_attachment(data_url, alt)
        if data_url =~ %r{\Adata:(image/[\w.+-]+);base64,(.+)\z}
          content_type = Regexp.last_match(1)
          data = Base64.decode64(Regexp.last_match(2))
          ext = Mime::Type.lookup(content_type).symbol.to_s
          filename = "import-#{SecureRandom.hex}.#{ext}"
          blob = ActiveStorage::Blob.create_and_upload!(io: StringIO.new(data), filename: filename, content_type: content_type)
          "<img src=\"#{Rails.application.routes.url_helpers.rails_blob_url(blob, only_path: true)}\" alt=\"#{alt}\" />"
        else
          "<img src=\"#{data_url}\" alt=\"#{alt}\" />"
        end
      end

      # Rewrite data-URI image references in Markdown source to point at
      # newly-created Active Storage blobs. Returns rewritten Markdown.
      #
      # Used by the inline Markdown editor to persist blob URLs in the stored
      # `markdown_source`, so subsequent text edits around the image do not
      # re-import the same data URI into a fresh blob on every autosave.
      def rewrite_data_uri_images(text)
        return text if text.nil?
        image_refs = {}

        # Protect fenced code blocks and inline code spans before rewriting —
        # a Markdown code sample like ```` ```md\n![x](data:...)\n``` ```` must
        # not be silently uploaded as a blob and have its source rewritten,
        # which would corrupt the user's code snippet on every autosave.
        with_code_protected(text.dup) do |result|
          # Collect reference-style data-URI image definitions. CommonMark accepts
          # both the angle-bracket form `[alt]: <data:...>` and the bare form
          # `[alt]: data:image/...`, optionally followed by a title. Rewrite each
          # definition to point at a freshly-uploaded blob, normalizing to the
          # bare form (titles are dropped since blob paths cannot collide with
          # surrounding text).
          result.gsub!(/^(\s*\[)([^\]]+)(\]:\s*)(?:<\s*(data:image\/[^>]+?)\s*>|(data:image\/\S+))(\s*(?:"[^"]*"|'[^']*'|\([^)]*\))?\s*)$/) do
            lead, label, mid, angle_url, bare_url, tail = $1, $2, $3, $4, $5, $6
            data_url = (angle_url || bare_url).strip
            blob_path = data_uri_to_blob_path(data_url)
            image_refs[label] = blob_path
            "#{lead}#{label}#{mid}#{blob_path}#{tail}"
          end

          # Inline data-URI images: ![alt](data:...) or ![alt](data:... "title")
          # → ![alt](blob_path) / ![alt](blob_path "title"). Parse the title
          # separately so it doesn't get captured into the data URL and break
          # strict matching in `data_uri_to_blob_path`. Titles may be
          # double-quoted, single-quoted, or parenthesized per CommonMark.
          result.gsub!(/(?<!\\)!\[([^\]]*)\]\(\s*(data:image\/[^\s)]+)(\s+(?:"[^"]*"|'[^']*'|\([^)]*\)))?\s*\)/) do
            alt, data_url, title = $1, $2, $3
            "![#{alt}](#{data_uri_to_blob_path(data_url)}#{title})"
          end

          result
        end
      end

      # Convert a data-URI to a freshly-uploaded Active Storage blob path.
      # Returns the original URL unchanged on parse failure.
      def data_uri_to_blob_path(data_url)
        return data_url unless data_url =~ %r{\Adata:(image/[\w.+-]+);base64,(.+)\z}

        content_type = Regexp.last_match(1)
        data = Base64.decode64(Regexp.last_match(2))
        ext = Mime::Type.lookup(content_type).symbol.to_s
        filename = "import-#{SecureRandom.hex}.#{ext}"
        blob = ActiveStorage::Blob.create_and_upload!(io: StringIO.new(data), filename: filename, content_type: content_type)
        Rails.application.routes.url_helpers.rails_blob_url(blob, only_path: true)
      end

      private

      # Run a regex-rewriting block on `text` with fenced code blocks and
      # inline code spans swapped for unique tokens, then restore the original
      # segments in the block's return value. Prevents data-URI rewrites from
      # touching code samples that happen to contain image syntax.
      def with_code_protected(text)
        segments = {}
        index = 0
        protected_text = text

        # Fenced code blocks (``` or ~~~, indented up to 3 spaces per CommonMark).
        protected_text.gsub!(/^([ \t]{0,3})(`{3,}|~{3,})[^\n]*\n[\s\S]*?\n\1\2[ \t]*(?=\n|\z)/) do |match|
          token = "\x00MDPROTECT#{index}\x00"
          segments[token] = match
          index += 1
          token
        end

        # Inline single-backtick code spans. Multi-backtick spans are rare in
        # practice; the protection above already covers fenced samples.
        protected_text.gsub!(/`[^`\n]+?`/) do |match|
          token = "\x00MDPROTECT#{index}\x00"
          segments[token] = match
          index += 1
          token
        end

        rewritten = yield(protected_text)
        segments.each { |token, original| rewritten.sub!(token, original) }
        rewritten
      end

      def escape_table_cell(text)
        text.to_s.gsub(/(?<!\\)\|/, '\\|')
      end

      def alignment_from_cell(cell)
        style = cell["style"].to_s
        align = cell["align"].to_s
        case
        when style =~ /text-align\s*:\s*center/i || align =~ /center/i
          :center
        when style =~ /text-align\s*:\s*right/i || align =~ /right/i
          :right
        when style =~ /text-align\s*:\s*left/i || align =~ /left/i
          :left
        else
          nil
        end
      end

      def alignment_marker(alignment)
        case alignment
        when :center then ":---:"
        when :right  then "---:"
        when :left   then ":---"
        else "---"
        end
      end

      def pad_cells(cells, expected_length)
        values = cells.dup
        values = values.first(expected_length)
        values.fill("", values.length...expected_length)
        values
      end
    end
  end
end
