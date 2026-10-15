# frozen_string_literal: true

module Collavre
  module Orchestration
    # Records one dispatch has already read, shared by the components that
    # decide it (ContextBuilder, Matcher, Arbiter, PolicyResolver).
    #
    # Each of them used to look the same comment, author and topic up again by
    # id. An instance lives exactly as long as the AgentOrchestrator that owns
    # it: it is never put in the context (which is persisted into task
    # payloads), never shared between dispatches, and never outlives the
    # request or job that built it, so no later decision can read a value
    # this one cached.
    #
    # Only records the dispatch is about are seeded: the comment that was just
    # committed, and its author. Everything else is loaded on first use, once.
    class DispatchRecords
      def self.for_comment(comment)
        records = new.seed(comment)
        author = comment.association(:user)
        records.seed(author.target) if author.loaded?
        records
      end

      def initialize
        @records = {}
      end

      def seed(record)
        @records[key(record.class, record.id)] = record if record&.persisted?
        self
      end

      # klass.find_by(id: id), read at most once per dispatch. A miss (nil) is
      # remembered too, so a dangling id is not looked up repeatedly either.
      def find(klass, id)
        return nil if id.blank?

        cache_key = key(klass, id)
        return @records[cache_key] if @records.key?(cache_key)

        @records[cache_key] = klass.find_by(id: id)
      end

      private

      def key(klass, id)
        [ klass.base_class, id.to_i ]
      end
    end
  end
end
