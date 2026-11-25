# frozen_string_literal: true

module Collavre
  module Tools
    class KeepService
      extend T::Sig
      extend ToolMeta

      tool_name "keep"
      tool_description "Start a bounded keep loop in a Collavre topic. Requires write permission. Uses the same validation and routing as /keep. Supply topic_id only; creative_id is derived from the topic."
      tool_param :max, description: "Maximum iterations, from 1 to 1000. Defaults to 10.", required: false
      tool_param :cooldown, description: "Delay after each completed task, from 0 to 3600 seconds. Defaults to 10; 0 checks immediately.", required: false
      tool_param :agent_name, description: "Exact agent name, without @ or colon. Omit to use normal topic routing.", required: false
      tool_param :goal, description: "Goal to pursue. Omit to continue the topic's current work.", required: false
      tool_param :topic_id, description: "Destination topic ID. No creative_id is needed."

      sig { params(max: Integer, cooldown: Integer, agent_name: T.nilable(String), goal: String, topic_id: Integer).returns(T::Hash[Symbol, T.untyped]) }
      def call(max: 10, cooldown: 10, agent_name: nil, goal: "", topic_id: 0)
        content = [ "/keep --max #{max} --cooldown #{cooldown}", ("@#{agent_name}:" if agent_name.present?), "--", goal ].compact.join(" ")
        MessageService.new.call(topic_id: topic_id, content: content)
      end

      class MessageService < TopicMessageCreateService
        private

        def dispatch_agent_message(comment, user, principal, selection, envelope)
          agents = super
          comment.send(:reconcile_loop_dispatch, agents)
        rescue StandardError
          comment.send(:reconcile_loop_dispatch, [], notify: false)
          raise
        end

        def prepare_comment!(comment)
          TopicAuthorizer.authorize_write!(comment.topic)
          error = Comments::KeepCommand.new(comment: comment, user: Current.user).call
          raise ArgumentError, error if error.present?
        end
      end
    end
  end
end
