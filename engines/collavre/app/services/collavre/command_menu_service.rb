module Collavre
  class CommandMenuService
    def initialize(user:)
      @user = user
    end

    def items
      built_in_items + mcp_items
    end

    private

    attr_reader :user

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
        {
          name: tool_name,
          label: "/#{tool_name}",
          description: tool[:description] || tool["description"],
          args: format_args(raw_params),
          input_schema: normalize_params(raw_params)
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
