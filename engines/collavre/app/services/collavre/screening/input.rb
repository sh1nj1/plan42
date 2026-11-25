# frozen_string_literal: true

module Collavre
  module Screening
    # Labels each text with where it came from and packs them into as few
    # judge inputs of at most MAX_CHARS as fit, so a turn usually costs one
    # judge call per screener.
    module Input
      MAX_CHARS = 60_000

      def self.chunks(texts)
        blocks = texts.flat_map do |entry|
          text = entry[:text].to_s
          next [] if text.strip.empty?

          label = "[source: #{entry[:source]}]\n"
          size = MAX_CHARS - label.length
          (0...text.length).step(size).map { |i| label + text[i, size] }
        end
        blocks.each_with_object([]) do |block, chunks|
          if chunks.last && chunks.last.length + block.length + 2 <= MAX_CHARS
            chunks.last << "\n\n" << block
          else
            chunks << block.dup
          end
        end
      end
    end
  end
end
