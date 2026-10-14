# frozen_string_literal: true

module Collavre
  # Shared validation keeps native and chat decisions on the same contract.
  # Chat probabilities are model estimates, not calibrated probabilities.
  class DecisionQuestions
    attr_reader :definitions

    def initialize(questions)
      raise ArgumentError, "A decision needs questions" if questions.blank?

      @definitions = questions.deep_stringify_keys
      definitions.each_value { |definition| answer_schema(definition) }
    end

    def schema
      properties = definitions.transform_values { |definition| answer_schema(definition) }
      { type: "object", properties: { answers: { type: "object", properties: properties,
        required: properties.keys, additionalProperties: false }, reason: { type: "string" } },
        required: %w[answers reason], additionalProperties: false }
    end

    def normalize(payload, source:)
      payload = payload.deep_stringify_keys
      answers = definitions.to_h do |name, definition|
        answer = payload.fetch("answers").fetch(name)
        type = definition.fetch("type").to_s
        value = answer.fetch(type)
        validate_value!(value, definition)
        [ name, { type => value } ]
      end
      { "answers" => answers, "reason" => payload.fetch("reason", "").to_s, "source" => source }
    end

    private

    def answer_schema(definition)
      type = definition.fetch("type").to_s
      value = case type
      when "choice"
        options = definition.fetch("options").keys.map(&:to_s)
        raise ArgumentError, "A choice needs options" if options.empty?
        { type: "string", enum: options }
      when "probability" then { type: "number", minimum: 0, maximum: 1 }
      when "score" then { type: "number", minimum: 0, maximum: definition.fetch("levels").size - 1 }
      else raise ArgumentError, "Unsupported question type: #{type}"
      end
      { type: "object", properties: { type => value }, required: [ type ], additionalProperties: false }
    end

    def validate_value!(value, definition)
      type = definition.fetch("type").to_s
      valid = if type == "choice"
        definition.fetch("options").key?(value)
      else
        maximum = type == "probability" ? 1 : definition.fetch("levels").size - 1
        value.is_a?(Numeric) && value.finite? && value.between?(0, maximum)
      end
      raise ArgumentError, "Invalid decision answer" unless valid
    end
  end
end
