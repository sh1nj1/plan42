# frozen_string_literal: true

module Collavre
  module Comments
    # Advances one user's read watermarks for a creative.
    #
    # Every pointer on the creative is read once and written once. The previous
    # implementation issued a find_by, a find_or_create_by! and a locking
    # read/modify/write per topic, so marking All Messages read cost four round
    # trips per rendered topic — on a networked database that count *was* the
    # response time.
    #
    # Monotonicity no longer depends on a row lock. Every lane goes through an
    # upsert that keeps the larger of the stored and the incoming watermark in
    # SQL, which is atomic, so a delayed request carrying an older watermark can
    # neither walk a pointer backwards nor collide on a first-time insert, even
    # though the read that produced it is no longer serialised with the write.
    # Because of that the request's own view can be stale, so the positions it
    # reports for broadcasting are read back after the write.
    class ReadPointerWriter
      class StaleTopicError < StandardError; end

      Change = Struct.new(:topic_id, :previous_id, :updated_id, :created, keyword_init: true) do
        def stored?
          created || previous_id != updated_id
        end

        def advanced?
          previous_id != updated_id
        end
      end

      def initialize(creative:, user:)
        @creative = creative
        @user = user
      end

      # last_ids_by_topic_id maps a topic id — or nil for the retained legacy
      # lane — to the newest comment that topic should now count as read.
      # Returns [topic_id, comment_id] positions whose receipts need repainting,
      # superseded positions first so the caller's last broadcast is the current
      # one.
      def call(last_ids_by_topic_id)
        return [] if last_ids_by_topic_id.empty?

        ActiveRecord::Base.transaction do
          locked_topic_ids = lock_named_topics!(last_ids_by_topic_id.keys)
          existing = existing_watermarks
          changes = last_ids_by_topic_id.map { |topic_id, last_id| change_for(existing, topic_id, last_id) }
          store(changes, existing, locked_topic_ids)
          # The request's own view of the watermark is not what the row now holds:
          # a concurrent writer may have advanced past it, in which case the
          # forward-only SQL kept *their* value. Broadcasting this request's
          # updated_id would repaint the receipt at a position the database has
          # already moved beyond, so read back what was actually retained.
          positions(changes, existing, existing_watermarks)
        end
      end

      private

      attr_reader :creative, :user

      def lock_named_topics!(topic_ids)
        ids = topic_ids.compact.map(&:to_i)
        ids.concat(creative.topics.ids) if topic_ids.include?(nil)
        ids = ids.uniq.sort
        return ids if ids.empty?

        locked = Topic.where(id: ids).order(:id).lock.pluck(:id, :creative_id)
        return ids if locked.length == ids.length && locked.all? { |_, creative_id| creative_id == creative.id }

        raise StaleTopicError, I18n.t("collavre.comments.invalid_topic")
      end

      def existing_watermarks
        CommentReadPointer.where(user: user, creative: creative).pluck(:topic_id, :last_read_comment_id).to_h
      end

      # An absent pointer is still materialised, exactly as find_or_create_by!
      # did: a named row is what stops a topic inheriting a later legacy
      # watermark it never displayed.
      def change_for(existing, topic_id, last_id)
        previous_id = existing[topic_id]
        Change.new(
          topic_id: topic_id,
          previous_id: previous_id,
          updated_id: [ previous_id, last_id ].compact.max,
          created: !existing.key?(topic_id)
        )
      end

      def store(changes, existing, locked_topic_ids)
        named, legacy = changes.partition { |change| change.topic_id.present? }
        upsert_named(named.select(&:stored?))
        legacy_change = legacy.first
        return unless legacy_change&.stored?

        preserve_named_fallbacks(legacy_change, existing, named, locked_topic_ids) if legacy_change.advanced?
        store_legacy(legacy_change)
      end

      # NULLs are distinct in a unique index, so this conflict target only covers
      # named rows. The legacy lane has its own partial unique index and is
      # written separately below.
      def upsert_named(changes)
        return if changes.empty?

        now = Time.current
        rows = changes.map do |change|
          {
            user_id: user.id,
            creative_id: creative.id,
            topic_id: change.topic_id,
            last_read_comment_id: change.updated_id,
            created_at: now,
            updated_at: now
          }
        end

        CommentReadPointer.upsert_all(
          rows,
          unique_by: :index_comment_read_pointers_on_user_creative_and_topic,
          on_duplicate: forward_only_assignment
        )
      end

      # GREATEST is not NULL-safe on SQLite (MAX(x, NULL) is NULL), and a NULL
      # watermark is meaningful here — it is the initial, nothing-read state.
      # Spell out [stored, incoming].compact.max so both adapters agree.
      def forward_only_assignment
        Arel.sql(<<~SQL.squish)
          last_read_comment_id = CASE
            WHEN comment_read_pointers.last_read_comment_id IS NULL THEN excluded.last_read_comment_id
            WHEN excluded.last_read_comment_id IS NULL THEN comment_read_pointers.last_read_comment_id
            WHEN excluded.last_read_comment_id > comment_read_pointers.last_read_comment_id
              THEN excluded.last_read_comment_id
            ELSE comment_read_pointers.last_read_comment_id
          END,
          updated_at = excluded.updated_at
        SQL
      end

      # The legacy lane has no topic_id, so it needs its own conflict target:
      # the partial unique index on (user_id, creative_id) WHERE topic_id IS
      # NULL. Going through the same upsert as named rows means a first-time
      # write racing another first-time write resolves in the database instead
      # of raising RecordNotUnique out of a bare create!.
      def store_legacy(change)
        now = Time.current
        row = {
          user_id: user.id,
          creative_id: creative.id,
          topic_id: nil,
          last_read_comment_id: change.updated_id,
          created_at: now,
          updated_at: now
        }

        CommentReadPointer.upsert_all(
          [ row ],
          unique_by: :index_comment_read_pointers_on_legacy_pointer,
          on_duplicate: forward_only_assignment
        )
      end

      # The legacy pointer is also the fallback watermark for any named topic
      # without its own row. Before moving it forward, pin those topics at the
      # fallback they were already showing, so an unseen older topic does not
      # silently inherit the new legacy value.
      def preserve_named_fallbacks(change, existing, named_changes, locked_topic_ids)
        covered_topic_ids = existing.keys.compact + named_changes.map(&:topic_id)
        now = Time.current
        rows = (locked_topic_ids - covered_topic_ids).map do |topic_id|
          {
            user_id: user.id,
            creative_id: creative.id,
            topic_id: topic_id,
            last_read_comment_id: change.previous_id,
            created_at: now,
            updated_at: now
          }
        end
        return if rows.empty?

        CommentReadPointer.insert_all(rows, unique_by: :index_comment_read_pointers_on_user_creative_and_topic)
      end

      # A newly created named pointer replaces whatever the legacy fallback was
      # rendering for that topic, so that receipt has to be repainted too.
      # `stored` is the post-write state, so a position is only cleared when the
      # row genuinely left it, and the current position is the retained one.
      def positions(changes, existing, stored)
        legacy_fallback_id = existing[nil]
        superseded = changes.flat_map do |change|
          current_id = stored[change.topic_id]
          [
            ([ change.topic_id, legacy_fallback_id ] if change.created && change.topic_id && legacy_fallback_id),
            ([ change.topic_id, change.previous_id ] if change.previous_id.present? && change.previous_id != current_id)
          ]
        end

        superseded.compact + changes.map { |change| [ change.topic_id, stored[change.topic_id] ] }.select(&:last)
      end
    end
  end
end
