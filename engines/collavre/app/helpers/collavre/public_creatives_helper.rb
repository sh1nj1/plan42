# frozen_string_literal: true

module Collavre
  # Text for the search and share metadata of a public creative's /p/ page.
  module PublicCreativesHelper
    PUBLIC_TITLE_MAX_LENGTH = 70
    PUBLIC_DESCRIPTION_MAX_LENGTH = 160
    PUBLIC_DESCRIPTION_CHILD_LIMIT = 20
    # Bounds the scan past denied children so a long hidden prefix still
    # reaches the public ones the client-side tree shows.
    PUBLIC_DESCRIPTION_CANDIDATE_LIMIT = 200
    # Elements whose text would otherwise run into the next block's
    # ("<p>A</p><p>B</p>" must read "A B", not "AB").
    PUBLIC_TEXT_BREAK_SELECTOR = "p, div, li, dt, dd, br, tr, td, th, h1, h2, h3, h4, h5, h6, pre, blockquote"

    def public_creative_title(creative)
      public_creative_text(creative.description).truncate(PUBLIC_TITLE_MAX_LENGTH).presence ||
        t("collavre.public_creatives.show.untitled")
    end

    # The outline under the title, in reading order: the first anonymous-readable
    # children. A creative without any falls back to its own text. Readability
    # uses the same batch filter as the client-side tree, so a linked child
    # hidden at its placement is skipped even when its origin is public.
    def public_creative_description(creative)
      candidates = creative.children.active.limit(PUBLIC_DESCRIPTION_CANDIDATE_LIMIT).to_a
      readable = Creatives::PermissionFilter.new(user: nil).readable_ids(candidates.map(&:id)).to_set
      texts = candidates.lazy
        .select { |child| readable.include?(child.id) }
        .map { |child| public_creative_text(child.effective_description) }
        .first(PUBLIC_DESCRIPTION_CHILD_LIMIT)
      text = texts.join(" ").squish.presence || public_creative_text(creative.description)
      text.truncate(PUBLIC_DESCRIPTION_MAX_LENGTH)
    end

    private

    def public_creative_text(html)
      fragment = Nokogiri::HTML5.fragment(html.to_s)
      fragment.css(PUBLIC_TEXT_BREAK_SELECTOR).each { |node| node.add_next_sibling(" ") }
      Collavre::HtmlText.label(fragment.to_html)
    end
  end
end
