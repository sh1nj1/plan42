# frozen_string_literal: true

module Collavre
  module Mobile
    # Owns the per-(user, device) ordinal namespace for the voice loop. Given the
    # current set of pending approvals and active sessions, it assigns/looks up a
    # stable ref_number for each, pins it across polling cycles, marks vanished
    # ones resolved, and resolves spoken references ("1번", "방금", "전부") back to
    # a concrete MobileVoiceRef. This is what lets the app say "작업 1, …" and the
    # human reply "1번 승인" and have the server hit the right approval.
    class RefRegistry
      STALE_RESOLVED_AFTER = 1.hour

      def initialize(user, device_id)
        @user = user
        @device_id = device_id.to_s
      end

      # --- assignment / lookup -------------------------------------------------

      def ref_for_approval(comment, label:, topic_id:)
        find_or_create(
          kind: "approval",
          topic_id: topic_id,
          target_comment_id: comment.id,
          request_id: comment.claude_channel_permission_request_id,
          label: label
        )
      end

      def ref_for_session(topic_id, label:)
        find_or_create(kind: "agent_session", topic_id: topic_id, label: label)
      end

      def active_refs
        scope.active.order(:ref_number)
      end

      # Reconcile: anything no longer present in the live sets is resolved so its
      # number is freed (after cleanup) and never spoken again as "active".
      def reconcile!(active_comment_ids:, active_topic_ids:)
        comment_ids = active_comment_ids.compact.to_set
        topic_ids   = active_topic_ids.compact.to_set
        scope.active.find_each do |ref|
          still =
            case ref.kind
            when "approval"      then comment_ids.include?(ref.target_comment_id)
            when "agent_session" then topic_ids.include?(ref.topic_id)
            else false
            end
          ref.resolve! unless still
        end
        cleanup_stale!
      end

      # --- spoken reference resolution ----------------------------------------

      # ref can be an Integer ("1번"), :last ("방금/마지막") or :all ("전부").
      # Returns an Array of MobileVoiceRef (empty if nothing matches).
      def resolve(ref)
        case ref
        when :all  then active_refs.to_a
        when :last then Array(most_recent)
        when Integer, /\A\d+\z/
          Array(scope.active.find_by(ref_number: ref.to_i))
        else
          []
        end
      end

      def most_recent
        scope.active.order(Arel.sql("COALESCE(last_seen_at, created_at) DESC")).first
      end

      private

      def scope
        MobileVoiceRef.for_device(@user.id, @device_id)
      end

      def find_or_create(kind:, topic_id:, label:, target_comment_id: nil, request_id: nil)
        existing =
          if target_comment_id
            scope.active.find_by(target_comment_id: target_comment_id)
          elsif kind == "agent_session"
            scope.active.find_by(kind: "agent_session", topic_id: topic_id)
          end

        if existing
          existing.update!(label: label, last_seen_at: Time.current, topic_id: topic_id,
                           request_id: request_id || existing.request_id)
          return existing
        end

        create_with_unique_number!(
          kind: kind, topic_id: topic_id, target_comment_id: target_comment_id,
          request_id: request_id, label: label
        )
      end

      # next_number races under concurrent polling; the unique index is the real
      # guard, so retry on collision rather than locking the whole namespace.
      def create_with_unique_number!(attrs)
        attempts = 0
        begin
          MobileVoiceRef.create!(
            attrs.merge(user: @user, device_id: @device_id, ref_number: next_number,
                        status: "active", last_seen_at: Time.current)
          )
        rescue ActiveRecord::RecordNotUnique
          attempts += 1
          retry if attempts < 5
          raise
        end
      end

      def next_number
        used = scope.pluck(:ref_number).to_set
        n = 1
        n += 1 while used.include?(n)
        n
      end

      def cleanup_stale!
        scope.resolved.where(last_seen_at: ..STALE_RESOLVED_AFTER.ago).delete_all
      end
    end
  end
end
