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

        # Find primary agent from @mentions using the same parsing as chat
        primary_agent = comment.mentioned_users.find(&:ai_user?)

        # User.mentionable_for resolves every searchable agent, including ones
        # with no share on this creative. Pinning such an agent would silence
        # the topic outright: the pin is exclusive (Matcher#match_by_primary_agent
        # suppresses the other agents' ambient routing) while the pinned agent
        # itself fails the feedback check and cannot answer either.
        if primary_agent && !Topic.primary_agent_assignable?(creative, primary_agent)
          return I18n.t("collavre.comments.topic_command.agent_no_creative_access",
                        agent: primary_agent.display_name)
        end

        # Find existing topic or create new one
        existing_topic = Topic.find_by(creative: creative, name: data[:name])

        if existing_topic&.session_id.present?
          # A Claude Channel session topic carries its agent as session identity,
          # not as a routing pin (see TopicsController#set_primary_agent). Neither
          # reassigning nor releasing it is safe from a chat command.
          return I18n.t("collavre.comments.topic_command.session_topic_locked",
                        name: existing_topic.name)
        end

        # Assigning or releasing a primary agent rewrites the topic's routing:
        # the pin decides who may speak here and silences every other agent. The
        # REST equivalents (TopicsController#set_primary_agent and #create, which
        # also accepts agent_id) require :write, but CommentsController#create
        # only authorizes the comment at :feedback, so the command has to apply
        # the same gate itself — otherwise commenting access would be enough to
        # decide a topic's routing. Checked before the new/existing split because
        # `/topic "new name" @agent` persists an exclusive assignment just as
        # much as moving one on a topic that already exists.
        if assigns_primary_agent?(existing_topic, primary_agent) &&
           !creative.has_permission?(user, :write)
          return I18n.t("collavre.comments.topic_command.not_authorized")
        end

        if existing_topic
          if primary_agent
            set_primary_agent(existing_topic, primary_agent)
            broadcast_topic_agent_updated(existing_topic, primary_agent)
            I18n.t("collavre.comments.topic_command.updated_agent",
                   name: existing_topic.name,
                   agent: primary_agent.name)
          elsif existing_topic.primary_agent_id
            # /topic "name" with no @mention on an already-assigned topic releases
            # the assignment — the keyboard counterpart of clicking the avatar off.
            set_primary_agent(existing_topic, nil)
            broadcast_topic_agent_updated(existing_topic, nil)
            I18n.t("collavre.comments.topic_command.cleared_agent",
                   name: existing_topic.name)
          else
            I18n.t("collavre.comments.topic_command.already_exists",
                   name: existing_topic.name)
          end
        else
          topic = Topic.create!(
            creative: creative,
            user: user,
            name: data[:name]
          )

          if primary_agent
            set_primary_agent(topic, primary_agent)
            broadcast_topic_created(topic, primary_agent)
            I18n.t("collavre.comments.topic_command.created_with_agent",
                   name: topic.name,
                   agent: primary_agent.name)
          else
            broadcast_topic_created(topic)
            I18n.t("collavre.comments.topic_command.created", name: topic.name)
          end
        end
      end

      def broadcast_topic_created(topic, agent = nil)
        data = { action: "created", topic: topic.slice(:id, :name), user_id: user.id }
        if agent
          data[:topic][:primary_agent] = {
            id: agent.id,
            name: agent.display_name,
            avatar_url: resolve_avatar_url(agent)
          }
        end
        TopicsChannel.broadcast_to(creative, data)
      end

      # Push an assignment change on an existing topic to every connected client.
      # :primary_agent is always present (nil when released) so the merge on the
      # client can actually remove the avatar rather than keep a stale one.
      def broadcast_topic_agent_updated(topic, agent)
        data = { action: "updated", topic: topic.slice(:id, :name), user_id: user.id }
        data[:topic][:primary_agent] = if agent
          { id: agent.id, name: agent.display_name, avatar_url: resolve_avatar_url(agent) }
        end
        TopicsChannel.broadcast_to(creative, data)
      end

      def resolve_avatar_url(agent)
        if agent.avatar.attached?
          Rails.application.routes.url_helpers.rails_blob_url(
            agent.avatar, only_path: true
          )
        elsif agent.avatar_url.present?
          agent.avatar_url
        else
          ActionController::Base.helpers.asset_path("default_avatar.svg")
        end
      end

      def set_primary_agent(topic, agent)
        topic.set_primary_agent!(agent)
      end

      # True when the command would write primary_agent_id: a mention assigns
      # (or moves) the pin on either a new or an existing topic, and a bare
      # /topic on an already assigned topic releases it. `/topic "name"` with no
      # mention writes no assignment — on an unassigned existing topic it only
      # reports that it already exists, and on a new one it creates a topic with
      # ambient routing intact — so both stay open to commenters, matching the
      # pre-existing rule that /topic can create topics at :feedback.
      def assigns_primary_agent?(topic, primary_agent)
        primary_agent.present? || topic&.primary_agent_id.present?
      end
    end
  end
end
