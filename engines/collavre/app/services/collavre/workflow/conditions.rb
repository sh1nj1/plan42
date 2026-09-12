# frozen_string_literal: true

module Collavre
  module Workflow
    class Conditions
      KEYS = %w[source author_agent body_contains liquid].freeze

      def self.match?(conditions, context)
        new(conditions, context).match?
      end

      def initialize(conditions, context)
        @conditions = conditions.to_h.stringify_keys
        @context = context
      end

      def match?
        KEYS.all? do |key|
          !@conditions.key?(key) || send("#{key}_matches?", @conditions[key])
        end
      end

      private

      def source_matches?(sources)
        envelope = SystemEvents::Envelope.in(@context)

        envelope.present? && Array(sources).include?(envelope.source)
      end

      def author_agent_matches?(expected)
        return false unless author

        expected == author.ai_user?
      end

      def body_contains_matches?(fragments)
        content = @context.dig("comment", "content")
        return false if content.nil?

        body = content.downcase
        Array(fragments).any? { |fragment| body.include?(fragment.to_s.downcase) }
      end

      def liquid_matches?(expression)
        expression = expression.strip
        expression = "{% if #{expression} %}true{% endif %}" unless expression.start_with?("{%")

        template = Liquid::Template.parse(expression)
        template.render(@context).strip == "true"
      rescue StandardError => e
        Rails.logger.error("[Workflow::Conditions] Liquid error: #{e.message}")
        false
      end

      def author
        return @author if defined?(@author)

        @author = User.find_by(id: @context.dig("comment", "user_id"))
      end
    end
  end
end
