module Creatives
  class FilterPipeline
    Result = Struct.new(
      :matched_ids,
      :allowed_ids,
      :progress_map,
      :overall_progress,
      keyword_init: true
    )

    # 필터 클래스 목록 - 순서대로 적용
    FILTERS = [
      Filters::ProgressFilter,
      Filters::TagFilter,
      Filters::SearchFilter,
      Filters::CommentFilter,
      Filters::DateFilter,
      Filters::AssigneeFilter
    ].freeze

    def initialize(user:, params:, scope:)
      @user = user
      @params = params
      @scope = scope
    end

    def call
      matched_ids = apply_filters
      return empty_result if matched_ids.empty?

      # 조상 포함
      allowed_ids = resolve_ancestors(matched_ids)

      # O(1) 권한 필터링
      allowed_ids = filter_by_permission(allowed_ids)

      progress_map, overall = calculate_progress(allowed_ids, matched_ids)

      Result.new(
        matched_ids: matched_ids.to_set,
        allowed_ids: allowed_ids.map(&:to_s).to_set,
        progress_map: progress_map,
        overall_progress: overall
      )
    end

    def any_filter_active?
      FILTERS.any? { |klass| klass.new(params: params, scope: scope).active? }
    end

    private

    attr_reader :user, :params, :scope

    def apply_filters
      active_filters = FILTERS
        .map { |klass| klass.new(params: params, scope: scope) }
        .select(&:active?)

      # 필터가 없으면 전체 반환
      return scope.pluck(:id) if active_filters.empty?

      # 모든 필터의 교집합
      matched_sets = active_filters.map { |f| f.match.to_set }
      matched_sets.reduce(:&).to_a
    end

    def resolve_ancestors(matched_ids)
      ancestors = CreativeHierarchy
        .where(descendant_id: matched_ids)
        .pluck(:ancestor_id)

      (matched_ids + ancestors).uniq
    end

    def filter_by_permission(ids)
      # O(1) 캐시 테이블 조회
      # no_access는 캐시에 없으므로 별도 체크 불필요
      user_conditions = user ? [ user.id, nil ] : [ nil ]

      accessible_ids = CreativeSharesCache
        .where(creative_id: ids, user_id: user_conditions)
        .pluck(:creative_id)

      # 소유한 Creative도 포함
      owned_ids = user ? Creative.where(id: ids, user_id: user.id).pluck(:id) : []

      (accessible_ids + owned_ids).uniq
    end

    def calculate_progress(allowed_ids, matched_ids)
      return [ {}, 0.0 ] if allowed_ids.empty?

      # Find "leaf-most" nodes: nodes that are NOT ancestors of other nodes in matched_ids
      # These are the relevant nodes for overall progress calculation
      superfluous_ancestors = CreativeHierarchy
        .where(ancestor_id: matched_ids.to_a, descendant_id: matched_ids.to_a)
        .where("generations > 0")
        .pluck(:ancestor_id)
        .uniq

      relevant_ids = matched_ids.to_a - superfluous_ancestors

      # Get progress values for all allowed creatives
      creatives = Creative.where(id: allowed_ids).includes(:origin)
      progress_values = creatives.to_h do |c|
        # Shell Creative uses origin's progress
        progress = c.origin_id.present? ? c.origin&.progress : c.progress
        [ c.id, progress || 0.0 ]
      end

      # Calculate overall progress from relevant (leaf-most) nodes only
      relevant_progress = relevant_ids.map { |id| progress_values[id] || 0.0 }
      overall = relevant_progress.any? ? relevant_progress.sum / relevant_progress.size : 0.0

      # Build progress_map: for each allowed_id, calculate average of its relevant descendants
      relationships = CreativeHierarchy
        .where(ancestor_id: allowed_ids, descendant_id: relevant_ids)
        .pluck(:ancestor_id, :descendant_id)

      aggregation = Hash.new { |h, k| h[k] = [] }
      relationships.each do |anc_id, desc_id|
        val = progress_values[desc_id]
        aggregation[anc_id] << val if val
      end

      progress_map = {}
      aggregation.each do |anc_id, values|
        progress_map[anc_id.to_s] = values.sum / values.size
      end

      # Also include nodes that are in relevant_ids themselves
      relevant_ids.each do |id|
        progress_map[id.to_s] ||= progress_values[id] || 0.0
      end

      [ progress_map, overall ]
    end

    def empty_result
      Result.new(
        matched_ids: Set.new,
        allowed_ids: Set.new,
        progress_map: {},
        overall_progress: 0.0
      )
    end
  end
end
