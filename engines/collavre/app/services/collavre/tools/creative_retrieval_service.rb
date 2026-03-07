module Collavre
require "sorbet-runtime"
require "rails_mcp_engine"
module Tools
  class CreativeRetrievalService
    extend T::Sig
    extend ToolMeta

    tool_name "creative_retrieval_service"
    tool_description "Retrieve creatives by ID or query text. Without query or ID, it returns root creatives.\n\nA Creative is a content block that functions like a task, organized in a tree structure similar to a to-do list. You can navigate the tree at any level as a structured document, with progress automatically calculated to show what's been completed.\n\nDefault output is a compact markdown tree:\n<!-- format: [id] description (progress%) -->\n- [123] My Task (50%)\n  - [124] Subtask A (100%)\n  - [125] Subtask B (0%)\n\ne.g.\n- When user say creative or Test creative, it means \"Test\" creative and it's children as a writing page.\n- Summary of Test creative? - you need to search \"Test\" creatives with level 3 or more and find the title is \"Test\" or similar and make summary of that."

    tool_param :id, description: "The ID of the creative to retrieve with its subtree."
    tool_param :query, description: "Text to search for in creative descriptions and comments."
    tool_param :level, description: "Creative tree depth to return (default: 3).", required: false
    tool_param :tags, description: "Filter by tag names (comma-separated).", required: false
    tool_param :progress_min, description: "Min progress filter (0.0-1.0).", required: false
    tool_param :progress_max, description: "Max progress filter (0.0-1.0).", required: false
    tool_param :updated_since, description: "ISO8601 timestamp - only items updated after this.", required: false
    tool_param :include_comments, description: "Include recent comments per creative (default: false).", required: false
    tool_param :format, description: "Response format: 'markdown' (default, compact tree) or 'json' (structured data with tags/dates).", required: false

    sig do
      params(
        id: T.nilable(Integer),
        query: T.nilable(String),
        level: T.nilable(Integer),
        tags: T.nilable(String),
        progress_min: T.nilable(Float),
        progress_max: T.nilable(Float),
        updated_since: T.nilable(String),
        include_comments: T.nilable(T::Boolean),
        format: T.nilable(String)
      ).returns(T.any(String, T::Array[T::Hash[Symbol, T.untyped]]))
    end
    def call(id: nil, query: nil, level: 3, tags: nil, progress_min: nil, progress_max: nil, updated_since: nil, include_comments: false, format: "markdown")
      level ||= 3
      format ||= "markdown"
      include_comments ||= false

      raise "Current.user is required" unless Current.user

      creatives = fetch_creatives(id: id, query: query)
      creatives = apply_filters(creatives, tags: tags, progress_min: progress_min, progress_max: progress_max, updated_since: updated_since)

      # Search queries return a flat list — no subtree expansion needed
      if query.present? && id.blank?
        creatives.map do |c|
          { id: c.id, description: Creatives::TreeFormatter.plain_description(c), progress: c.progress.to_f.round(2) }
        end
      elsif format == "json"
        build_json_tree(creatives, depth: level, include_comments: include_comments)
      else
        formatter = Creatives::TreeFormatter.new(
          max_depth: level - 1,
          include_header: true,
          include_comments: include_comments
        )
        formatter.format(creatives) + "\n"
      end
    end

    private

    def fetch_creatives(id:, query:)
      if id.present?
        creative = Creative.find_by(id: id)
        return [] unless creative && creative.has_permission?(Current.user, :read)
        [ creative ]
      elsif query.present?
        search_creatives(query)
      else
        Creative.where(user: Current.user).roots.order(:sequence).to_a
      end
    end

    def search_creatives(query)
      sanitized = Creative.sanitize_sql_like(query)
      pattern = "%#{sanitized}%"

      # Scope search to user's own + shared creatives via permission cache
      accessible_ids = accessible_creative_ids

      desc_ids = Creative.where(id: accessible_ids)
                         .where("description LIKE ?", pattern)
                         .pluck(:id)

      comment_ids = Comment.where(creative_id: accessible_ids)
                           .where("content LIKE ?", pattern)
                           .pluck(:creative_id)

      combined_ids = (desc_ids | comment_ids)
      return [] if combined_ids.empty?

      Creative.where(id: combined_ids)
              .sort_by { |c| c.description.to_s.length }
    end

    def accessible_creative_ids
      # User's own creatives + those shared via permission cache
      own_ids = Creative.where(user: Current.user).pluck(:id)
      shared_ids = CreativeSharesCache
                     .where(user_id: Current.user.id)
                     .where.not(permission: :no_access)
                     .pluck(:creative_id)
      own_ids | shared_ids
    end

    def apply_filters(creatives, tags:, progress_min:, progress_max:, updated_since:)
      result = creatives

      if tags.present?
        tag_names = tags.split(",").map(&:strip)
        label_ids = Label.where(value: tag_names).pluck(:id)
        tagged_ids = Tag.where(label_id: label_ids).pluck(:creative_id).to_set
        # Batch: find which input creatives have tagged descendants (single query)
        creative_ids = result.map(&:id)
        ancestors_with_tagged = CreativeHierarchy
          .where(ancestor_id: creative_ids)
          .where(descendant_id: tagged_ids.to_a)
          .pluck(:ancestor_id)
          .to_set
        result = result.select { |c| tagged_ids.include?(c.id) || ancestors_with_tagged.include?(c.id) }
      end

      if progress_min.present?
        result = result.select { |c| c.progress.to_f >= progress_min.to_f }
      end

      if progress_max.present?
        result = result.select { |c| c.progress.to_f <= progress_max.to_f }
      end

      if updated_since.present?
        since = Time.parse(updated_since)
        # Batch check: get all descendant IDs with updates, then filter
        creative_ids = result.map(&:id)
        updated_descendant_ancestors = CreativeHierarchy
          .where(ancestor_id: creative_ids)
          .joins("INNER JOIN creatives ON creatives.id = creative_hierarchies.descendant_id")
          .where("creatives.updated_at >= ?", since)
          .pluck(:ancestor_id)
          .to_set

        result = result.select { |c| c.updated_at >= since || updated_descendant_ancestors.include?(c.id) }
      end

      result
    end

    # --- JSON format ---

    def build_json_tree(creatives, depth:, include_comments: false)
      return [] if creatives.blank?

      creatives.map do |creative|
        serialize_creative(creative, depth: depth, current_depth: 1, include_comments: include_comments)
      end
    end

    def serialize_creative(creative, depth:, current_depth:, include_comments: false)
      children = creative.linked_children

      result = {
        id: creative.id,
        description: Creatives::TreeFormatter.plain_description(creative),
        progress: creative.progress.to_f.round(2),
        parent_id: creative.parent_id,
        tags: creative.tags.includes(:label).map { |t| t.label&.value }.compact,
        linked: creative.origin_id.present?,
        origin_id: creative.origin_id,
        has_children: children.any?,
        children_count: children.size,
        created_at: creative.created_at&.iso8601,
        updated_at: creative.updated_at&.iso8601
      }

      if include_comments
        result[:recent_comments] = creative.comments.order(created_at: :desc).limit(3).map do |comment|
          {
            content: ActionView::Base.full_sanitizer.sanitize(comment.content).strip.truncate(200),
            user: comment.user&.display_name || comment.user&.name,
            created_at: comment.created_at&.iso8601
          }
        end
      end

      if current_depth < depth
        result[:children] = children.map do |child|
          serialize_creative(child, depth: depth, current_depth: current_depth + 1, include_comments: include_comments)
        end
      else
        result[:children] = []
      end

      result
    end
  end
end
end
