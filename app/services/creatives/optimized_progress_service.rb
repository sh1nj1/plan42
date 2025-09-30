module Creatives
  class OptimizedProgressService < ProgressService
    # 태그별 진행률 계산을 배치로 최적화
    def self.progress_for_tags_batch(creatives, tag_ids, user)
      return {} if creatives.blank? || tag_ids.blank?
      
      # 한 번에 모든 태그 정보 조회 (N+1 쿼리 방지)
      creative_ids = creatives.map(&:id)
      tag_map = build_tag_map(creative_ids, tag_ids)
      
      # 권한이 있는 크리에이티브만 필터링
      accessible_creatives = creatives.select { |c| c.has_permission?(user, :read) }
      
      result = {}
      accessible_creatives.each do |creative|
        result[creative.id] = new(creative).calculate_progress_for_creative(creative, tag_ids, tag_map, user)
      end
      
      result
    end
    
    def progress_for_tags_optimized(tag_ids, user)
      return creative.progress if tag_ids.blank?
      
      tag_ids = Array(tag_ids).map(&:to_s)
      
      # 서브트리의 모든 크리에이티브 ID 조회
      subtree_ids = creative.self_and_descendants.pluck(:id)
      
      # 한 번에 모든 태그 정보 조회
      tag_map = self.class.build_tag_map(subtree_ids, tag_ids)
      
      calculate_progress_recursive(creative, tag_ids, tag_map, user)
    end
    
    def calculate_progress_for_creative(creative, tag_ids, tag_map, user)
      calculate_progress_recursive(creative, tag_ids, tag_map, user) || 0
    end
    
    private
    
    def self.build_tag_map(creative_ids, tag_ids)
      tags = Tag.includes(:label)
                .where(creative_id: creative_ids, label_id: tag_ids)
      
      tag_map = {}
      tags.each do |tag|
        tag_map[tag.creative_id] ||= []
        tag_map[tag.creative_id] << tag.label_id.to_s
      end
      tag_map
    end
    
    def calculate_progress_recursive(current_creative, tag_ids, tag_map, user)
      visible_children = current_creative.children_with_permission(user)
      
      if visible_children.any?
        child_values = visible_children.map do |child|
          calculate_progress_recursive(child, tag_ids, tag_map, user)
        end.compact
        
        child_values.any? ? child_values.sum.to_f / child_values.size : nil
      else
        # 리프 노드인 경우 태그 매칭 확인
        own_label_ids = tag_map[current_creative.id] || []
        if (own_label_ids & tag_ids).any?
          current_creative.progress
        end
      end
    end
  end
end
