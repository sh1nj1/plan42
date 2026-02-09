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
          name_match = content.match(/[\u201c\u201d""]([^"\u201c\u201d""]+)[\u201c\u201d""]|"([^"]+)"/)
          topic_name = name_match ? (name_match[1] || name_match[2]) : nil

          return if topic_name.blank?

          { name: topic_name }
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

        # Find primary agent from @mentions using the same parsing as chat
        primary_agent = comment.mentioned_users.find(&:ai_user?)

        if primary_agent
          set_primary_agent(topic, primary_agent)
          I18n.t("collavre.comments.topic_command.created_with_agent",
                 name: topic.name,
                 agent: primary_agent.name)
        else
          I18n.t("collavre.comments.topic_command.created", name: topic.name)
        end
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
