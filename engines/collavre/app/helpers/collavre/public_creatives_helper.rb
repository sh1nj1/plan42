# frozen_string_literal: true

module Collavre
  module PublicCreativesHelper
    PUBLIC_HEADING_MAX_LENGTH = 120
    PUBLIC_BLOCK_SELECTOR = "a, br, table, ul, ol, img, video, iframe, pre, blockquote, hr, h1, h2, h3, h4, h5, h6"

    # A creative whose description is a short, single line of text reads as a
    # section title, so it becomes a heading in the outline. Anything richer —
    # several paragraphs, a list, a table, media — is rendered as body content.
    def public_creative_heading?(creative)
      html = creative.description.to_s
      label = Collavre::HtmlText.label(html)
      return false if label.blank? || label.length > PUBLIC_HEADING_MAX_LENGTH

      fragment = Nokogiri::HTML5.fragment(html)
      fragment.css(PUBLIC_BLOCK_SELECTOR).empty? && fragment.css("p").size <= 1 && fragment.children.count { |node| node.text.strip.present? } <= 1
    end

    def public_creative_body(creative)
      fragment = Nokogiri::HTML5.fragment(creative.description.to_s)
      first_block = fragment.children.find { |node| node.text.strip.present? }
      return fragment.to_html unless first_block

      simple_title = %w[p h1 h2 h3 h4 h5 h6].include?(first_block.name) &&
        first_block.css(PUBLIC_BLOCK_SELECTOR).empty?
      first_block.remove if simple_title && first_block.text.squish.length <= Creative::TITLE_MAX_LENGTH
      fragment.to_html
    end

    # The page title is the only <h1>; depth below it maps onto h2..h6.
    def public_creative_heading_tag(level)
      "h#{(level + 1).clamp(2, 6)}"
    end
  end
end
