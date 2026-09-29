# frozen_string_literal: true

module Collavre
  # Groups agent tools by name prefix for the agent form. Engines register
  # their own categories (see collavre_github's engine initializer).
  class McpToolCategories
    Category = Data.define(:key, :prefixes, :label_key)

    CUSTOM = :custom
    OTHER = :other

    @categories = []

    class << self
      def register(key, prefixes:, label_key: "collavre.tool_categories.#{key}")
        key = key.to_sym
        @categories = @categories.reject { |category| category.key == key } +
                      [ Category.new(key, Array(prefixes), label_key) ]
      end

      def key_for(name)
        name = name.to_s
        @categories.find { |category| category.prefixes.any? { |prefix| name.start_with?(prefix) } }&.key || OTHER
      end

      # tools: [{ name:, custom: }]. Returns non-empty groups in registration
      # order, followed by user-defined (custom) tools and uncategorized ones.
      def group(tools)
        grouped = Array(tools).group_by { |tool| tool[:custom] ? CUSTOM : key_for(tool[:name]) }

        ordered_keys.filter_map do |key|
          next if grouped[key].blank?

          { key: key, label: label_for(key), tools: grouped[key] }
        end
      end

      private

      def ordered_keys
        @categories.map(&:key) + [ CUSTOM, OTHER ]
      end

      def label_for(key)
        category = @categories.find { |c| c.key == key }
        I18n.t(category&.label_key || "collavre.tool_categories.#{key}")
      end
    end

    register :creative, prefixes: "creative_"
    register :topic, prefixes: "topic_"
    register :source, prefixes: "collavre_source_"
    register :cron, prefixes: "cron_"
    register :preview, prefixes: "preview_"
    register :approval, prefixes: "approval_"
  end
end
