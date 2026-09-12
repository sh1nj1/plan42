# frozen_string_literal: true

module Collavre
  module Workflow
    # Presents authoring data only; dispatch still applies the target's permissions.
    class Editor
      def initialize(creative, user, placement: creative)
        @creative = creative
        @user = user
        @placement = placement
      end

      def as_json
        {
          workflow_id: @creative.id,
          rules: visible_rules.map { |rule| rule_json(rule) },
          event_names: SystemEvents::Vocabulary.names,
          sources_by_event: SystemEvents::Vocabulary.names.to_h do |name|
            [ name, SystemEvents::Vocabulary.fetch(name).sources ]
          end,
          agents: agents,
          permission_note: I18n.t("collavre.workflow.editor.permission_note"),
          can_manage: admin_ids.include?(@placement.id)
        }
      end

      def rule_json(creative)
        parsed, errors = Rule.parse(creative)
        {
          id: creative.id, description: creative.description,
          rule: creative.data["workflow_rule"], errors: errors,
          valid: parsed.present?, warnings: rule_warnings(parsed),
          can_manage: admin_ids.include?(@creative.id) && admin_ids.include?(creative.id)
        }
      end

      private

      def visible_rules
        ids = Creatives::PermissionFilter.new(user: @user).readable_ids(children.map(&:id))
        children.select { |child| ids.include?(child.id) && child.workflow_rule? }
      end

      def children
        @children ||= @creative.children.active.order(:sequence, :id).to_a
      end

      def admin_ids
        @admin_ids ||= Creatives::PermissionFilter.new(user: @user)
          .readable_ids([ @creative.id, @placement.id, *children.map(&:id) ], min_permission: :admin).to_set
      end

      def agents
        @agents ||= visible_agents.map do |agent|
          allowed = @creative.has_permission?(agent, :feedback)
          { id: agent.id, name: agent.name, can_respond_here: allowed,
            warnings: allowed ? [] : [ I18n.t("collavre.workflow.editor.agent_cannot_respond_here") ] }
        end
      end

      def visible_agents
        owned_or_searchable = User.accessible_ai_agents_for(@user)
        shared = User.mentionable_for(@creative).ai_agents
        owned_or_searchable.or(shared).order(:name, :id)
      end

      def rule_warnings(rule)
        return [] unless rule&.responder?

        options = agents.index_by { |agent| agent[:id] }
        rule.agent_ids.flat_map do |id|
          option = options[id]
          option ? option[:warnings] : [ I18n.t("collavre.workflow.editor.agent_unavailable") ]
        end.uniq
      end
    end
  end
end
