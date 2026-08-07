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
  end
end
