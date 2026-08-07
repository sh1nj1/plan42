module Collavre
  # Single source of truth for rendering stored HTML (creative descriptions,
  # comment bodies) as plain text for titles, labels, snippets and AI prompts.
  #
  # Every caller used to hand-roll `strip_tags` and, at best, pair it with
  # `CGI.unescapeHTML`. That pair is broken: `strip_tags` runs
  # Rails::HTML5::FullSanitizer, whose HTML5 serializer re-encodes U+00A0 as the
  # named reference `&nbsp;`, while `CGI.unescapeHTML` only decodes the five XML
  # entities plus numeric references. The literal six-character string `&nbsp;`
  # therefore survived into labels (and got re-escaped to `&amp;nbsp;` on
  # render, so users saw `&nbsp;` on screen) and counted against truncation
  # limits. Re-parsing the stripped output as an HTML fragment decodes every
  # named reference instead.
  module HtmlText
    module_function

    # Tags stripped, character references decoded exactly once. Whitespace is
    # preserved as authored, so U+00A0 stays U+00A0 — use `label` for anything
    # rendered on a single line.
    def plain(html)
      stripped = ActionController::Base.helpers.strip_tags(html.to_s)
      return "" if stripped.empty?

      Nokogiri::HTML5.fragment(stripped).text
    end

    # Single-line plain text for titles, labels and breadcrumbs. `squish`
    # collapses every run of Unicode whitespace — U+00A0 included — into one
    # ASCII space.
    def label(html)
      plain(html).squish
    end

    # `label` capped at `length`, matching String#truncate semantics.
    def truncated_label(html, length, omission: "...")
      label(html).truncate(length, omission: omission)
    end

    # Characters that would start a markdown construct where a label gets
    # interpolated. `]` and `)` let a title close the generated link early and
    # supply its own destination; `<` and `>` make marked emit inline HTML that
    # the client sanitizer then deletes; the rest turn a label into emphasis, a
    # code span or strikethrough.
    MARKDOWN_SPECIAL = /[\\`*_\[\]()<>~]/
    private_constant :MARKDOWN_SPECIAL

    # Backslash-escapes markdown constructs so `text` renders as the literal
    # characters the author typed. One pass over the string, so the backslashes
    # this adds are never themselves escaped.
    def escape_markdown(text)
      text.to_s.gsub(MARKDOWN_SPECIAL) { |char| "\\#{char}" }
    end

    # `label` (optionally capped at `length`) escaped for interpolation into
    # generated markdown, as in `"[#{markdown_label(html, 30)}](#{path})"`.
    #
    # Truncation happens before escaping so `length` counts the characters a
    # reader sees, and a cut can never land inside a backslash escape.
    def markdown_label(html, length = nil, omission: "...")
      text = length ? truncated_label(html, length, omission: omission) : label(html)
      escape_markdown(text)
    end
  end
end
