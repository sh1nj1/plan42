module Collavre
  module Comments
    module Concerns
      module WorkflowSupport
        extend ActiveSupport::Concern

        private

        # Filter creatives that already have active tasks or are completed
        # Returns array of creative IDs to skip
        def filter_active_or_completed(creative_ids)
          return [] if creative_ids.empty?

          # Skip creatives with active tasks (done/failed/cancelled allow re-work)
          active = Task.where(creative_id: creative_ids)
                       .where(status: %w[running queued pending pending_approval])
                       .pluck(:creative_id)

          # Skip creatives already completed (progress >= 1.0)
          completed = Creative.where(id: creative_ids)
                              .where("progress >= 1.0")
                              .pluck(:id)

          (active + completed).uniq
        end

        # DFS traversal of creative tree
        def dfs_traverse(node, &block)
          yield node
          node.children.order(:sequence).each { |child| dfs_traverse(child, &block) }
        end

        # Find the original user who triggered the workflow
        # Looks in: comment author → stored user_id → creative owner → agent
        def find_original_user_from_task(task)
          comment_id = task.trigger_event_payload&.dig("comment", "id")
          comment = Comment.find_by(id: comment_id) if comment_id

          # Try: comment author → stored user_id → creative owner → agent (last resort)
          user = comment&.user
          user ||= User.find_by(id: task.trigger_event_payload&.dig("comment", "user_id"))
          user ||= task.creative&.user
          user ||= task.agent

          Rails.logger.warn("[WorkflowSupport] Using fallback user (#{user&.class}:#{user&.id}) for task ##{task.id}") unless comment&.user

          user
        end

        # Post a notice comment to the original creative thread
        def post_workflow_notice(task, content)
          comment_id = task.trigger_event_payload&.dig("comment", "id")
          unless comment_id
            Rails.logger.warn("[WorkflowSupport] post_workflow_notice: no comment_id in trigger_event_payload: #{task.trigger_event_payload.inspect}")
            return
          end

          original_comment = Comment.find_by(id: comment_id)
          unless original_comment
            Rails.logger.warn("[WorkflowSupport] post_workflow_notice: comment #{comment_id} not found")
            return
          end

          Rails.logger.info("[WorkflowSupport] post_workflow_notice: posting to creative #{original_comment.creative_id}")
          original_comment.creative.comments.create!(
            content: content,
            user: task.agent,
            topic_id: original_comment.topic_id
          )
        end

        # Resolve workflow context: if it's a creative ID, render that creative's markdown
        def resolve_workflow_context_from_task(task, state)
          # Use cached rendered context if available (avoids re-rendering in job context)
          cached = state["rendered_workflow_context"]
          return cached if cached.present?

          context_text = task.workflow_context.to_s.strip
          creative_id = context_text[/\A\d+\z/]

          resolved = if creative_id
                       context_creative = Creative.find_by(id: creative_id)
                       if context_creative
                         markdown = render_creative_markdown_for_task(task, context_creative)
                         markdown.presence || context_text
                       else
                         context_text
                       end
          else
                       context_text
          end

          # Cache for subsequent sub-tasks
          state["rendered_workflow_context"] = resolved
          task.update!(workflow_state: state)

          resolved
        end

        # Render creative tree as markdown with agent's depth settings
        def render_creative_markdown_for_task(task, creative)
          max_depth = task.agent.creative_children_level + 1
          result = ApplicationController.helpers.render_creative_tree_markdown(
            [ creative ], 1, true, max_depth: max_depth
          )
          Rails.logger.info("[WorkflowSupport] render_creative_markdown: creative=#{creative.id} result_length=#{result&.length}")
          result
        rescue StandardError => e
          Rails.logger.error("[WorkflowSupport] render_creative_markdown FAILED: creative=#{creative.id} error=#{e.class}: #{e.message}\n#{e.backtrace&.first(5)&.join("\n")}")
          nil
        end
      end
    end
  end
end
