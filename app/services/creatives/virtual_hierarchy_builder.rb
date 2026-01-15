module Creatives
  class VirtualHierarchyBuilder
    def initialize(creative_link)
      @link = creative_link
      @parent = creative_link.parent
      @origin = creative_link.origin
    end

    def build
      entries = []

      # 1. parent의 모든 조상 찾기 (parent 자신 포함)
      #    - 실제 조상 (CreativeHierarchy)
      parent_ancestors = CreativeHierarchy
        .where(descendant_id: @parent.id)
        .pluck(:ancestor_id, :generations)
        .to_h
      parent_ancestors[@parent.id] = 0  # 자기 자신

      #    - 가상 조상 (VirtualCreativeHierarchy) - 중첩 링크 지원
      virtual_ancestors = VirtualCreativeHierarchy
        .where(descendant_id: @parent.id)
        .pluck(:ancestor_id, :generations)
        .to_h
      virtual_ancestors.each do |ancestor_id, gen|
        # 실제 조상보다 가상 조상이 더 가까우면 가상 조상 사용
        parent_ancestors[ancestor_id] = gen unless parent_ancestors.key?(ancestor_id) && parent_ancestors[ancestor_id] <= gen
      end

      # 2. Origin의 모든 자손 찾기 (Origin 자신 포함)
      origin_descendants = CreativeHierarchy
        .where(ancestor_id: @origin.id)
        .pluck(:descendant_id, :generations)
        .to_h
      origin_descendants[@origin.id] = 0  # 자기 자신

      # 3. 가상 엔트리 생성: 각 조상 -> 각 Origin 자손
      now = Time.current
      parent_ancestors.each do |ancestor_id, gen_to_parent|
        origin_descendants.each do |descendant_id, gen_from_origin|
          total_generations = gen_to_parent + 1 + gen_from_origin

          entries << {
            ancestor_id: ancestor_id,
            descendant_id: descendant_id,
            generations: total_generations,
            creative_link_id: @link.id,
            created_at: now,
            updated_at: now
          }
        end
      end

      VirtualCreativeHierarchy.insert_all(entries) if entries.any?
    end

    # Origin에 새 자식이 추가될 때 호출
    def self.propagate_new_descendant(origin, new_descendant)
      links = CreativeLink.where(origin_id: origin.id)

      links.find_each do |link|
        add_virtual_entries_for_descendant(link, new_descendant)
      end

      # origin 자체가 누군가의 자손이면, 그 origin들에 대해서도 전파
      origin_ancestors = CreativeHierarchy
        .where(descendant_id: origin.id)
        .where.not(ancestor_id: origin.id)
        .pluck(:ancestor_id)

      origin_ancestors.each do |ancestor_id|
        links_to_ancestor = CreativeLink.where(origin_id: ancestor_id)
        links_to_ancestor.find_each do |link|
          add_virtual_entries_for_descendant(link, new_descendant)
        end
      end
    end

    def self.add_virtual_entries_for_descendant(link, new_descendant)
      parent_ancestors = CreativeHierarchy
        .where(descendant_id: link.parent_id)
        .pluck(:ancestor_id, :generations)
        .to_h
      parent_ancestors[link.parent_id] = 0

      gen_from_origin = CreativeHierarchy
        .find_by(ancestor_id: link.origin_id, descendant_id: new_descendant.id)
        &.generations || 0

      now = Time.current
      entries = parent_ancestors.map do |ancestor_id, gen_to_parent|
        {
          ancestor_id: ancestor_id,
          descendant_id: new_descendant.id,
          generations: gen_to_parent + 1 + gen_from_origin,
          creative_link_id: link.id,
          created_at: now,
          updated_at: now
        }
      end

      VirtualCreativeHierarchy.insert_all(entries) if entries.any?
    end

    # Origin에서 자손이 제거될 때 호출
    def self.remove_virtual_entries_for_descendant(descendant)
      VirtualCreativeHierarchy.where(descendant_id: descendant.id).delete_all
    end
  end
end
