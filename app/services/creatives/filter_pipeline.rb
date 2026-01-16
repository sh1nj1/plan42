module Creatives
  class FilterPipeline
    Result = Struct.new(
      :matched_ids,
      :allowed_ids,
      :progress_map,
      :overall_progress,
      keyword_init: true
    )

    FILTERS = [
      Filters::TagFilter,
      Filters::ProgressFilter,
      Filters::SearchFilter,
      Filters::CommentFilter
    ].freeze

    def initialize(user:, params:, scope:)
      @user = user
      @params = params.respond_to?(:with_indifferent_access) ? params.with_indifferent_access : params
      @scope = scope
    end

    def call
      matched_ids = apply_filters
      return empty_result if matched_ids.empty?

      # Virtual hierarchy 덕분에 조상 해석이 단순해짐
      allowed_ids = resolve_ancestors(matched_ids)

      # 권한 필터링
      allowed_ids = filter_by_permission(allowed_ids)

      progress_map, overall = calculate_progress_map(allowed_ids, matched_ids)

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
        .map { |klass| klass.new(user: user, params: params, scope: scope) }
        .select(&:active?)

      return scope.pluck(:id) if active_filters.empty?

      matched_sets = active_filters.map { |f| f.match.to_set }
      matched_sets.reduce(:&).to_a
    end

    def resolve_ancestors(matched_ids)
      # 실제 hierarchy에서 조상 찾기
      real_ancestors = CreativeHierarchy
        .where(descendant_id: matched_ids)
        .pluck(:ancestor_id)

      # 가상 hierarchy에서 조상 찾기
      virtual_ancestors = VirtualCreativeHierarchy
        .where(descendant_id: matched_ids)
        .pluck(:ancestor_id)

      (matched_ids + real_ancestors + virtual_ancestors).uniq
    end

    def filter_by_permission(ids)
      # O(1) 권한 체크: CreativeShare 테이블 직접 조회
      # user_id = nil 인 경우 public share (모든 사용자 접근 가능)
      # inherited: true/false 모두 포함 (inherited share가 있으면 접근 가능)
      user_conditions = user ? [ user.id, nil ] : [ nil ]
      accessible_ids = CreativeShare
        .where(creative_id: ids, user_id: user_conditions)
        .where.not(permission: :no_access)
        .pluck(:creative_id)

      # 소유한 Creative도 포함 (로그인 사용자만)
      owned_ids = user ? Creative.where(id: ids, user_id: user.id).pluck(:id) : []

      (accessible_ids + owned_ids).uniq
    end

    def calculate_progress_map(allowed_ids, matched_ids)
      # 이제 effective_progress 없이 그냥 progress 사용
      creatives = Creative.where(id: allowed_ids).pluck(:id, :progress)

      progress_map = creatives.to_h { |id, prog| [ id.to_s, prog || 0.0 ] }

      matched_progress = creatives.select { |id, _| matched_ids.include?(id) }
      overall = matched_progress.any? ?
        matched_progress.sum { |_, p| p || 0.0 } / matched_progress.size : 0.0

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
