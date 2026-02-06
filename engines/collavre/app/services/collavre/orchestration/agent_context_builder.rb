module Collavre
  module Orchestration
    # Builds context for AI agents including:
    # - Agent identity
    # - Available collaborators from Creative permissions
    # - Organization hierarchy derived from permission levels
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

      def initialize(agent:, creative:)
        @agent = agent
        @creative = creative
      end

      # Returns hash suitable for Liquid template rendering
      def build
        {
          "agent" => build_agent_identity,
          "collaborators" => build_collaborators,
          "collaboration_guide" => build_collaboration_guide
        }
      end

      # Generates markdown-formatted collaboration section for system prompt
      def to_collaboration_prompt
        collaborators = build_collaborators
        return "" if collaborators.empty?

        sections = []

        sections << "## 협업 가능한 Agent"
        sections << ""

        # Group by role
        by_role = collaborators.group_by { |c| c["role"] }

        if by_role["escalation"]&.any?
          sections << "### 에스컬레이션 대상 (문제 해결 불가 시)"
          by_role["escalation"].each do |c|
            sections << "- @#{c['name']}: #{c['description']}"
          end
          sections << ""
        end

        if by_role["collaborator"]&.any?
          sections << "### 협업 가능 (함께 작업)"
          by_role["collaborator"].each do |c|
            sections << "- @#{c['name']}: #{c['description']}"
          end
          sections << ""
        end

        if by_role["reviewer"]&.any?
          sections << "### 리뷰어 (검토 요청)"
          by_role["reviewer"].each do |c|
            sections << "- @#{c['name']}: #{c['description']}"
          end
          sections << ""
        end

        if by_role["reference"]&.any?
          sections << "### 참조 (정보 요청만)"
          by_role["reference"].each do |c|
            sections << "- @#{c['name']}: #{c['description']}"
          end
          sections << ""
        end

        sections << "## 협업 규칙"
        sections << "- 다른 Agent 호출: @이름 요청내용"
        sections << "- 확신이 낮으면 재검토 후 발화"
        sections << "- 막히면 에스컬레이션 대상에게 도움 요청"
        sections << "- 코드 리뷰가 필요하면 리뷰어에게 요청"
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
          "mention_format" => "@이름 요청내용",
          "escalation_hint" => "확신이 낮거나 막히면 에스컬레이션 대상에게 도움 요청",
          "review_hint" => "코드 리뷰나 검토가 필요하면 리뷰어에게 요청"
        }
      end
    end
  end
end
