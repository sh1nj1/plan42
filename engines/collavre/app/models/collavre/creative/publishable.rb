module Collavre
  class Creative < ApplicationRecord
    # Stable, search-engine-friendly addresses for publicly readable creatives.
    #
    # A public page lives at /p/:public_id/:slug. The public_id is a random,
    # non-sequential token assigned the first time a creative is published and
    # never changed afterwards, so a revoked-then-restored share keeps its old
    # address. The id only locates a creative — it never grants access: every
    # public page re-checks `publicly_readable?` (the anonymous read permission).
    #
    # Linked creatives have no page of their own; callers resolve to the
    # effective origin first so one piece of content has one canonical address.
    module Publishable
      extend ActiveSupport::Concern

      PUBLIC_ID_LENGTH = 10
      PUBLIC_ID_FORMAT = /[0-9A-Za-z]{#{PUBLIC_ID_LENGTH}}/
      SLUG_MAX_LENGTH = 60
      PUBLIC_ID_ATTEMPTS = 5
      TITLE_MAX_LENGTH = 120
      TITLE_BLOCK_SELECTOR = "p, li, h1, h2, h3, h4, h5, h6, th, td, blockquote, pre"

      def publicly_readable?
        has_permission?(nil, :read)
      end

      # Assigns a public_id if the creative has none yet and returns it.
      # Written with a conditional update_all so it skips model callbacks
      # (a read-only-source creative must still be publishable) and so two
      # concurrent first visits converge on whichever token landed first.
      def ensure_public_id!
        return public_id if public_id.present?

        PUBLIC_ID_ATTEMPTS.times do
          candidate = SecureRandom.alphanumeric(PUBLIC_ID_LENGTH)
          begin
            self.class.where(id: id, public_id: nil).update_all(public_id: candidate)
          rescue ActiveRecord::RecordNotUnique
            next
          end
          stored = self.class.where(id: id).pick(:public_id)
          if stored.present?
            self[:public_id] = stored
            clear_attribute_change(:public_id)
            return stored
          end
        end

        raise ActiveRecord::RecordNotSaved.new("Could not assign a public id", self)
      end

      # The page title: the first block of text in the description, so a rich
      # description (a heading line followed by a list, say) is titled by its
      # opening line rather than by every block run together.
      def public_title
        fragment = Nokogiri::HTML5.fragment(effective_origin.description.to_s)
        first_block = first_public_title_block(fragment)
        (first_block || fragment).text.squish.truncate(TITLE_MAX_LENGTH)
      end

      def first_public_title_block(node)
        first = node.children.find { |child| child.text.strip.present? }
        return unless first
        return first if first.text? || first.css("#{TITLE_BLOCK_SELECTOR}, div, section, article, ul, ol, table").empty?

        first_public_title_block(first)
      end
      private :first_public_title_block

      # Human-readable URL segment derived from the title. Letters and digits of
      # every script are kept (so Korean titles stay Korean), everything else
      # collapses to single hyphens.
      def public_slug
        self.class.public_slug_for(public_title)
      end

      class_methods do
        def public_slug_for(text)
          slug = text.to_s.downcase.gsub(/[^\p{L}\p{N}]+/, "-").delete_prefix("-").delete_suffix("-")
          slug[0, SLUG_MAX_LENGTH].delete_suffix("-")
        end
      end
    end
  end
end
