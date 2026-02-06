module Collavre
  module Comments
    class TopicCommand
      def initialize(comment:, user:, url_helpers: Collavre::Engine.routes.url_helpers)
        @comment = comment
        @user = user
        @creative = comment.creative.effective_origin
        @url_helpers = url_helpers
      end

      def call
        return unless topic_command?

        create_topic
      rescue StandardError => e
        Rails.logger.error("Topic command failed: #{e.message}")
        e.message
      end

      private

      attr_reader :comment, :user, :creative, :url_helpers

      # /topic "topic name" @agent_name
      # /topic "topic name"
      COMMAND_PATTERN = /\A\/topic\b/i.freeze

      def topic_command?
        comment.content.to_s.strip.match?(COMMAND_PATTERN)
      end

      def parsed_args
        @parsed_args ||= begin
          content = comment.content.to_s.strip

          # Extract topic name in quotes
          name_match = content.match(/[""]([^""]+)[""]|"([^"]+)"/)
          topic_name = name_match ? (name_match[1] || name_match[2]) : nil

          return if topic_name.blank?

          # Extract @mentions for primary agent
          agent_match = content.match(/@(\w+)/)
          agent_name = agent_match ? agent_match[1] : nil

          {
            name: topic_name,
            agent_name: agent_name
          }
        end
      end

      def create_topic
        data = parsed_args
        return I18n.t("collavre.comments.topic_command.missing_name") if data.blank?

        # Create new topic
        topic = Topic.create!(
          creative: creative,
          user: user,
          name: data[:name]
        )

        # Set primary agent if specified
        primary_agent = find_agent(data[:agent_name]) if data[:agent_name].present?

        if primary_agent
          set_primary_agent(topic, primary_agent)
          I18n.t("collavre.comments.topic_command.created_with_agent",
                 name: topic.name,
                 agent: primary_agent.name)
        else
          if data[:agent_name].present?
            I18n.t("collavre.comments.topic_command.created_agent_not_found",
                   name: topic.name,
                   agent_name: data[:agent_name])
          else
            I18n.t("collavre.comments.topic_command.created", name: topic.name)
          end
        end
      end

      def find_agent(name)
        # Find AI agent by name (case-insensitive)
        user_class = Collavre.configuration.user_class_name.constantize
        user_class.where.not(llm_vendor: [ nil, "" ])
                  .where("LOWER(name) = ?", name.downcase)
                  .first
      end

      def set_primary_agent(topic, agent)
        OrchestratorPolicy.create!(
          policy_type: "arbitration",
          scope_type: "Topic",
          scope_id: topic.id,
          config: {
            "strategy" => "primary_first",
            "primary_agent_id" => agent.id
          },
          priority: 10,
          enabled: true
        )
      end
    end
  end
end
