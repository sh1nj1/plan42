# frozen_string_literal: true

module Collavre
  module Workflow
    class Conditions
      KEYS = %w[source author_agent body_contains liquid].freeze

      def self.match?(conditions, context, rule_id: nil)
        new(conditions, context, rule_id: rule_id).match?
      end

      def self.valid_liquid?(expression)
        return true if expression.nil?

        parse_liquid(expression, error_mode: :strict)
        true
      rescue Liquid::SyntaxError
        false
      end

      def self.parse_liquid(expression, error_mode: :lax)
        expression = expression.strip
        expression = "{% if #{expression} %}true{% endif %}" unless expression.start_with?("{%")
        Liquid::Template.parse(expression, error_mode: error_mode)
      end

      def initialize(conditions, context, rule_id: nil)
        @conditions = conditions
        @context = context
        @rule_id = rule_id
      end

      def match?(conditions = @conditions, rule_id: @rule_id)
        @conditions = conditions.to_h.stringify_keys
        @rule_id = rule_id

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
        template = self.class.parse_liquid(expression)
        template.render(@context.except("agent", :agent)).strip == "true"
      rescue StandardError => e
        Rails.logger.error("[Workflow::Conditions] Liquid error=#{e.class.name} rule_id=#{@rule_id.inspect}")
        false
      end

      def author
        return @author if defined?(@author)

        @author = User.find_by(id: @context.dig("comment", "user_id"))
      end
    end
  end
end
