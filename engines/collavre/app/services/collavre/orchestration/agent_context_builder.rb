module Collavre
  module Orchestration
    # Builds context for AI agents including:
    # - Agent identity
    # - Available collaborators from Creative permissions
    # - Organization hierarchy derived from permission levels
    # - Sender context for A2A communication
    #
    # Permission → Role mapping:
    # - admin:    escalation targets (supervisors)
    # - write:    peers (collaborators)
    # - feedback: reviewers
    # - read:     information sources only
    class AgentContextBuilder
      PERMISSION_ROLES = {
        "admin" => "escalation",    # Can escalate issues to
        "write" => "collaborator",  # Can collaborate with
        "feedback" => "reviewer",   # Can request reviews from
        "read" => "reference"       # Can request information from
      }.freeze

      def initialize(agent:, creative:, sender: nil, policy_resolver: nil)
        @agent = agent
        @creative = creative
        @sender = sender
        @policy_resolver = policy_resolver
      end

      def a2a_request?
        @sender && @sender["is_ai"] == true
      end

      # Returns hash suitable for Liquid template rendering
      def build
        result = {
          "agent" => build_agent_identity,
          "collaborators" => build_collaborators,
          "collaboration_guide" => build_collaboration_guide,
          "is_a2a" => a2a_request?
        }

        result["sender"] = @sender if @sender
        result
      end

      # Generates markdown-formatted collaboration section for system prompt
      def to_collaboration_prompt
        sections = []
        collab = collaboration_policy_config

        # Add A2A request context if this is an agent-to-agent call
        if a2a_request?
          sections << I18n.t("collavre.ai_agent.a2a.request_header")
          sections << ""
          sections << I18n.t("collavre.ai_agent.a2a.request_description",
                             sender_name: @sender["name"], sender_type: @sender["type"])
          sections << (collab["a2a_focus_instruction"] || I18n.t("collavre.ai_agent.a2a.focus_instruction"))
          sections << (collab["a2a_completion_instruction"] ||
                       I18n.t("collavre.ai_agent.a2a.completion_instruction",
                              sender_name: @sender["name"]))
          sections << (collab["a2a_followup_instruction"] || I18n.t("collavre.ai_agent.a2a.followup_instruction"))
          sections << ""
        elsif @sender
          # Human-triggered request: instruct agent to report back
          sections << I18n.t("collavre.ai_agent.a2a.human_completion_instruction",
                             sender_name: @sender["name"])
          sections << ""
        end

        collaborators = build_collaborators
        return sections.join("\n") if collaborators.empty?

        sections << I18n.t("collavre.ai_agent.collaboration.header")
        sections << ""

        # Group by role
        by_role = collaborators.group_by { |c| c["role"] }

        if by_role["escalation"]&.any?
          sections << I18n.t("collavre.ai_agent.collaboration.escalation_header")
          by_role["escalation"].each do |c|
            sections << "- @#{c['name']}: #{c['description']}"
          end
          sections << ""
        end

        if by_role["collaborator"]&.any?
          sections << I18n.t("collavre.ai_agent.collaboration.collaborator_header")
          by_role["collaborator"].each do |c|
            sections << "- @#{c['name']}: #{c['description']}"
          end
          sections << ""
        end

        if by_role["reviewer"]&.any?
          sections << I18n.t("collavre.ai_agent.collaboration.reviewer_header")
          by_role["reviewer"].each do |c|
            sections << "- @#{c['name']}: #{c['description']}"
          end
          sections << ""
        end

        if by_role["reference"]&.any?
          sections << I18n.t("collavre.ai_agent.collaboration.reference_header")
          by_role["reference"].each do |c|
            sections << "- @#{c['name']}: #{c['description']}"
          end
          sections << ""
        end

        sections << I18n.t("collavre.ai_agent.collaboration.rules_header")
        sections << (collab["mention_rule"] || I18n.t("collavre.ai_agent.collaboration.mention_rule"))
        sections << (collab["confidence_rule"] || I18n.t("collavre.ai_agent.collaboration.confidence_rule"))
        if @policy_resolver&.self_reflection_enabled?
          sections << I18n.t("collavre.ai_agent.collaboration.confidence_format_instruction")
        end
        sections << (collab["escalation_rule"] || I18n.t("collavre.ai_agent.collaboration.escalation_rule"))
        sections << (collab["review_rule"] || I18n.t("collavre.ai_agent.collaboration.review_rule"))
        sections << ""

        sections.join("\n")
      end

      private

      def build_agent_identity
        {
          "id" => @agent.id,
          "name" => @agent.name,
          "display_name" => @agent.display_name,
          "type" => extract_agent_type
        }
      end

      def extract_agent_type
        # Extract agent type from system_prompt or default
        prompt = @agent.system_prompt.to_s.downcase
        case prompt
        when /developer|개발/ then "developer"
        when /pm|project.?manager|프로젝트/ then "pm"
        when /qa|test|quality|테스트|품질/ then "qa"
        when /research|조사|연구/ then "researcher"
        when /market|마케팅/ then "marketer"
        when /plan|기획/ then "planner"
        else "agent"
        end
      end

      def build_collaborators
        return [] unless @creative

        # Get all AI agents with access to this creative tree
        ai_agents_with_access.map do |user, permission|
          next if user.id == @agent.id # Skip self

          {
            "id" => user.id,
            "name" => user.name,
            "display_name" => user.display_name,
            "role" => PERMISSION_ROLES[permission] || "reference",
            "permission" => permission,
            "description" => extract_agent_description(user)
          }
        end.compact
      end

      def ai_agents_with_access
        # Collect AI agents from creative and its ancestors
        creatives_to_check = [ @creative ] + @creative.ancestors.to_a

        agent_permissions = {}

        creatives_to_check.each do |creative|
          creative.creative_shares.includes(:user).each do |share|
            user = share.user
            next unless user&.ai_user?
            next if share.permission == "no_access"

            # Keep highest permission level
            current = agent_permissions[user]
            if current.nil? || permission_rank(share.permission) > permission_rank(current)
              agent_permissions[user] = share.permission
            end
          end
        end

        agent_permissions.to_a
      end

      def permission_rank(permission)
        CreativeShare.permissions[permission.to_s] || 0
      end

      def extract_agent_description(user)
        prompt = user.system_prompt.to_s
        # Extract first meaningful line or sentence
        first_line = prompt.lines.find { |l| l.strip.present? && !l.start_with?("#") }
        return "AI Agent" unless first_line

        # Truncate to reasonable length
        first_line.strip.truncate(100)
      end

      def build_collaboration_guide
        {
          "mention_format" => I18n.t("collavre.ai_agent.collaboration.mention_rule"),
          "escalation_hint" => I18n.t("collavre.ai_agent.collaboration.escalation_rule"),
          "review_hint" => I18n.t("collavre.ai_agent.collaboration.review_rule")
        }
      end

      def collaboration_policy_config
        @policy_resolver&.collaboration_config || {}
      end
    end
  end
end
