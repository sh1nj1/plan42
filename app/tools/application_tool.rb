# frozen_string_literal: true

class ApplicationTool < ActionTool::Base
  # write your custom logic to be shared across all tools here

  def self.as_json(options = {})
    {
      name: tool_name,
      description: description,
      inputSchema: sanitize_schema(input_schema_to_json)
    }
  end

  def self.sanitize_schema(schema)
    return schema unless schema.is_a?(Hash)

    schema.each_with_object({}) do |(key, value), result|
      if key == :not && value.is_a?(Hash) && value[:type] == "null"
        # Skip "not: { type: 'null' }" as it causes issues with some LLMs
        next
      elsif value.is_a?(Hash)
        result[key] = sanitize_schema(value)
      elsif value.is_a?(Array)
        result[key] = value.map { |v| v.is_a?(Hash) ? sanitize_schema(v) : v }
      else
        result[key] = value
      end
    end
  end
end
