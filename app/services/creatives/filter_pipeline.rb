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
      Filters::SearchFilter
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
      creatives = Creative.where(id: allowed_ids).pluck(:id, :progress)
      progress_map = creatives.to_h { |id, p| [ id.to_s, p || 0.0 ] }

      matched = creatives.select { |id, _| matched_ids.include?(id) }
      overall = matched.any? ? matched.sum { |_, p| p || 0.0 } / matched.size : 0.0

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
