module Collavre
  class CommandMenuService
    def initialize(user:, creative: nil)
      @user = user
      @creative = creative
    end

    def items
      built_in_items + mcp_items
    end

    private

    attr_reader :user, :creative

    def built_in_items
      [
        {
          name: "calendar",
          label: "/calendar",
          aliases: [ "/cal" ],
          description: I18n.t("collavre.comments.command_menu.calendar_description"),
          args: I18n.t("collavre.comments.command_menu.calendar_args"),
          input_schema: [
            { name: "date", type: "string", required: true, description: I18n.t("collavre.comments.command_menu.calendar_date_hint") },
            { name: "memo", type: "string", required: false, description: I18n.t("collavre.comments.command_menu.calendar_memo_hint") }
          ]
        },
        {
          name: "topic",
          label: "/topic",
          description: I18n.t("collavre.comments.command_menu.topic_description"),
          args: I18n.t("collavre.comments.command_menu.topic_args"),
          input_schema: [
            { name: "topic_name", type: "string", required: true, description: I18n.t("collavre.comments.command_menu.topic_name_hint") },
            { name: "agent_name", type: "string", format: "mention", required: false, description: I18n.t("collavre.comments.command_menu.topic_agent_hint") }
          ]
        },
        {
          name: "work",
          label: "/work",
          description: I18n.t("collavre.comments.command_menu.work_description"),
          args: I18n.t("collavre.comments.command_menu.work_args"),
          input_schema: [
            { name: "agent_name", type: "string", format: "mention", required: true, description: I18n.t("collavre.comments.command_menu.work_agent_hint") },
            { name: "context", type: "string", required: false, description: I18n.t("collavre.comments.command_menu.work_context_hint") }
          ]
        },
        {
          name: "compress",
          label: "/compress",
          description: I18n.t("collavre.comments.command_menu.compress_description"),
          args: I18n.t("collavre.comments.command_menu.compress_args"),
          input_schema: [
            { name: "instructions", type: "string", required: false, description: I18n.t("collavre.comments.command_menu.compress_instructions_hint") }
          ]
        },
        {
          name: "creative",
          label: "/creative",
          type: "popup",
          popup_type: "creative_picker",
          description: I18n.t("collavre.comments.command_menu.creative_description")
        }
      ]
    end

    def mcp_items
      Collavre::McpService.available_tools(user).filter_map do |tool|
        tool_name = tool[:name] || tool["name"]
        next unless tool_name

        raw_params = tool[:params] || tool["params"]
        schema = normalize_params(raw_params)
        defaults = tool_defaults_for(tool_name)
        apply_defaults_to_schema(schema, defaults) if defaults.present?

        {
          name: tool_name,
          label: "/#{tool_name}",
          description: tool[:description] || tool["description"],
          args: format_args(raw_params),
          input_schema: schema
        }
      end
    end

    def normalize_params(params)
      return nil if params.blank?

      if params.is_a?(Array)
        return params.map do |param|
          {
            name: (param[:name] || param["name"]).to_s,
            type: (param[:type] || param["type"] || "string").to_s,
            required: param[:required] || param["required"] || false,
            description: param[:description] || param["description"],
            enum: param[:enum] || param["enum"]
          }.compact
        end
      end

      properties = params[:properties] || params["properties"]
      return unless properties.is_a?(Hash)

      required = Array(params[:required] || params["required"] || []).map(&:to_s)
      properties.map do |key, value|
        key = key.to_s
        {
          name: key,
          type: (value[:type] || value["type"] || "string").to_s,
          required: required.include?(key),
          description: value[:description] || value["description"],
          enum: value[:enum] || value["enum"]
        }.compact
      end
    end

    def tool_defaults_for(tool_name)
      creative&.data&.dig("tools", tool_name)
    end

    def apply_defaults_to_schema(schema, defaults)
      return unless schema.is_a?(Array) && defaults.is_a?(Hash)

      schema.each do |param|
        name = param[:name]
        if defaults.key?(name)
          param[:default_value] = defaults[name]
        end
      end
    end

    def format_args(params)
      return if params.blank?

      if params.is_a?(Array)
        return params.map do |param|
          name = param[:name] || param["name"]
          required = param[:required] || param["required"]
          name.to_s + (required ? "*" : "")
        end.join(", ")
      end

      properties = params[:properties] || params["properties"]
      return unless properties.is_a?(Hash)

      required = params[:required] || params["required"] || []
      required = Array(required).map(&:to_s)

      properties.keys.map do |key|
        key = key.to_s
        required.include?(key) ? "#{key}*" : key
      end.join(", ")
    end
  end
end
