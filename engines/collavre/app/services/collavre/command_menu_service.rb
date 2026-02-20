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
          args: I18n.t("collavre.comments.command_menu.calendar_args")
        },
        {
          name: "topic",
          label: "/topic",
          description: I18n.t("collavre.comments.command_menu.topic_description"),
          args: I18n.t("collavre.comments.command_menu.topic_args")
        },
        {
          name: "work",
          label: "/work",
          description: I18n.t("collavre.comments.command_menu.work_description"),
          args: I18n.t("collavre.comments.command_menu.work_args")
        }
      ]
    end

    def mcp_items
      Collavre::McpService.available_tools(user).filter_map do |tool|
        tool_name = tool[:name] || tool["name"]
        next unless tool_name

        {
          name: tool_name,
          label: "/#{tool_name}",
          description: tool[:description] || tool["description"],
          args: format_args(tool[:params] || tool["params"])
        }
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
