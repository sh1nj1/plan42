# frozen_string_literal: true

module Collavre
  # Shared validation keeps native and chat decisions on the same contract.
  # Chat probabilities are model estimates, not calibrated probabilities.
  class DecisionQuestions
    attr_reader :definitions

    def initialize(questions)
      raise ArgumentError, "A decision needs questions" if questions.blank?

      @definitions = questions.deep_stringify_keys
      definitions.each do |name, definition|
        validate_question!(name, definition)
        answer_schema(definition)
      end
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
        validate_value!(value, definition, source: source)
        [ name, { type => value } ]
      end
      { "answers" => answers, "reason" => payload.fetch("reason", "").to_s, "source" => source }
    end

    private

    def validate_question!(name, definition)
      raise ArgumentError, "A question name cannot be empty" if name.empty?
      raise ArgumentError, "Each question must be a Hash" unless definition.is_a?(Hash)

      criteria_key = { "choice" => "options", "probability" => "criteria", "score" => "levels" }
        .fetch(definition["type"].to_s) { raise ArgumentError, "Unsupported question type" }
      extra = definition.keys - [ "type", "instructions", criteria_key ]
      raise ArgumentError, "Unknown question options: #{extra.join(', ')}" unless extra.empty?
    end

    def answer_schema(definition)
      unless description?(definition["instructions"])
        raise ArgumentError, "Question instructions must be text, a Hash, an Array, or nil"
      end

      type = definition.fetch("type").to_s
      value = case type
      when "choice"
        choice_schema(definition)
      when "probability" then probability_schema(definition)
      when "score" then score_schema(definition)
      else raise ArgumentError, "Unsupported question type: #{type}"
      end
      { type: "object", properties: { type => value }, required: [ type ], additionalProperties: false }
    end

    def choice_schema(definition)
      options = definition.fetch("options")
      unless options.is_a?(Hash) && options.size >= 2
        raise ArgumentError, "A choice needs at least two options"
      end
      raise ArgumentError, "Choice options must have nonempty names" if options.keys.any?(&:empty?)
      unless options.values.all? { |value| description?(value) }
        raise ArgumentError, "Choice descriptions must be text, a Hash, an Array, or nil"
      end

      { type: "string", enum: options.keys.map(&:to_s) }
    end

    def description?(value)
      value.nil? || [ String, Hash, Array ].any? { |type| value.is_a?(type) }
    end

    def probability_schema(definition)
      criteria = definition["criteria"]
      validate_probability_criteria!(criteria) unless criteria.nil?
      { type: "number", minimum: 0, maximum: 1 }
    end

    def validate_probability_criteria!(criteria)
      unless criteria.is_a?(Hash) && (criteria.keys - %w[yes no true false]).empty?
        raise ArgumentError, "Probability criteria must describe yes and no"
      end

      outcomes = criteria.keys.map { |key| %w[yes true].include?(key) }
      raise ArgumentError, "Probability criteria contain duplicate outcomes" unless outcomes.uniq.size == outcomes.size
      unless criteria.values.all? { |value| description?(value) }
        raise ArgumentError, "Probability descriptions must be text, a Hash, an Array, or nil"
      end
    end

    def score_schema(definition)
      levels = definition.fetch("levels")
      unless levels.is_a?(Array) && levels.all? { |level| description?(level) }
        raise ArgumentError, "Score levels must be an Array of descriptions"
      end

      count = levels.size
      raise ArgumentError, "A score needs 2 to 10 levels" unless (2..10).cover?(count)

      { type: "integer", minimum: 0, maximum: count - 1 }
    end

    def validate_value!(value, definition, source:)
      type = definition.fetch("type").to_s
      valid = if type == "choice"
        definition.fetch("options").key?(value)
      else
        maximum = type == "probability" ? 1 : definition.fetch("levels").size - 1
        value.is_a?(Numeric) && value.finite? && value.between?(0, maximum) &&
          (type != "score" || source == "judge" || value.is_a?(Integer))
      end
      raise ArgumentError, "Invalid decision answer" unless valid
    end
  end
end
