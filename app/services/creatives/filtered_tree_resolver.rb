require "set"

module Creatives
  class FilteredTreeResolver
    Result = Struct.new(:allowed_ids, :progress_map, keyword_init: true)

    FILTER_KEYS = %w[tags min_progress max_progress comment search calculate_progress].freeze

    def initialize(user:, params:, calculate_progress: false)
      @user = user
      @params = normalize_params(params)
      @calculate_progress = calculate_progress
    end

    def call(collection)
      return Result.new(allowed_ids: nil, progress_map: nil) unless filters_applied?

      visible_nodes = collect_visible_nodes(Array(collection))
      preload_associations!(visible_nodes)

      allowed_ids = build_allowed_ids(visible_nodes)
      progress_map = calculate_progress? ? build_progress_map(allowed_ids, visible_nodes) : nil

      Result.new(allowed_ids: allowed_ids, progress_map: progress_map)
    end

    private

    attr_reader :user, :params

    def calculate_progress?
      @calculate_progress
    end

    def filters_applied?
      filtered_values = params.slice(*FILTER_KEYS).except(:calculate_progress, "calculate_progress")
      filtered_values.any? { |_k, v| v.present? }
    end

    def collect_visible_nodes(collection)
      nodes = []
      queue = collection.compact
      visited = Set.new

      until queue.empty?
        current = queue.shift
        next if current.nil?
        next if visited.include?(current.id)

        visited.add(current.id)
        next unless readable?(current)

        nodes << current
        queue.concat(current.children_with_permission(user))
      end

      nodes
    end

    def readable?(creative)
      creative.user == user || creative.has_permission?(user, :read)
    end

    def build_allowed_ids(visible_nodes)
      return Set.new if visible_nodes.empty?

      matching_nodes = visible_nodes.select { |creative| matches_filter?(creative) }
      return Set.new if matching_nodes.empty?

      visible_id_set = visible_nodes.map(&:id).to_set
      matched_ids = matching_nodes.map(&:id)
      ancestor_ids = CreativeHierarchy.where(descendant_id: matched_ids).pluck(:ancestor_id)
      Set.new((matched_ids + ancestor_ids).uniq & visible_id_set.to_a)
    end

    def matches_filter?(creative)
      if tag_ids.present?
        creative_label_ids = creative.tags.map { |t| t.label_id.to_s }
        return false if (creative_label_ids & tag_ids).empty?
      end

      if min_progress
        return false if creative.progress.to_f < min_progress
      end

      if max_progress
        return false if creative.progress.to_f > max_progress
      end

      if comment_filter?
        return false unless creative.comments.any?
      end

      if search_term
        description_text = ActionView::Base.full_sanitizer.sanitize(creative.description.to_s)
        comment_texts = creative.comments.map(&:content).join(" ")
        return false unless description_text.include?(search_term) || comment_texts.include?(search_term)
      end

      true
    end

    def tag_ids
      @tag_ids ||= Array(params[:tags]).map(&:to_s)
    end

    def min_progress
      @min_progress ||= params[:min_progress]&.to_f
    end

    def max_progress
      @max_progress ||= params[:max_progress]&.to_f
    end

    def comment_filter?
      ActiveModel::Type::Boolean.new.cast(params[:comment])
    end

    def search_term
      @search_term ||= params[:search].presence
    end

    def build_progress_map(allowed_ids, visible_nodes)
      return {} if allowed_ids.blank?

      nodes_by_id = visible_nodes.index_by(&:id)
      children_by_parent = Hash.new { |hash, key| hash[key] = [] }

      allowed_ids.each do |id|
        node = nodes_by_id[id]
        next unless node

        parent_id = node.parent_id
        next unless parent_id
        next unless allowed_ids.include?(parent_id)

        children_by_parent[parent_id] << node
      end

      memo = {}
      allowed_ids.each do |id|
        progress_for(id, nodes_by_id, children_by_parent, memo)
      end
      memo
    end

    def progress_for(id, nodes_by_id, children_by_parent, memo)
      return memo[id] if memo.key?(id)

      node = nodes_by_id[id]
      children = children_by_parent[id] || []
      memo[id] = if children.any?
                   values = children.map { |child| progress_for(child.id, nodes_by_id, children_by_parent, memo) }.compact
                   values.any? ? values.sum.to_f / values.size : 0.0
      else
                   node&.progress.to_f
      end
    end

    def preload_associations!(nodes)
      associations = []
      associations << :tags if tag_ids.present?
      associations << :comments if comment_filter? || search_term
      return if associations.empty?

      ActiveRecord::Associations::Preloader.new(records: nodes, associations: associations).call
    end

    def normalize_params(params)
      params_hash = if params.respond_to?(:to_unsafe_h)
                      params.to_unsafe_h
      elsif params.respond_to?(:to_h)
                      params.to_h
      else
                      params
      end

      params_hash.with_indifferent_access
    end
  end
end
