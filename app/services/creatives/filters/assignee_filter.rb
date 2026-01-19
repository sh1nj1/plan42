module Creatives
  module Filters
    class AssigneeFilter < BaseFilter
      def active?
        params[:assignee_id].present? || params[:unassigned].present?
      end

      def match
        if params[:unassigned] == "true"
          # owner가 없는 Label을 가진 creative 또는 태그가 없는 creative
          with_null_owner = scope.left_joins(tags: :label)
                                 .where(labels: { owner_id: nil })
                                 .pluck(:id)
          without_tags = scope.left_joins(:tags)
                              .where(tags: { id: nil })
                              .pluck(:id)
          (with_null_owner + without_tags).uniq
        else
          assignee_ids = Array(params[:assignee_id]).map(&:to_i)
          scope.joins(tags: :label)
               .where(labels: { owner_id: assignee_ids })
               .distinct
               .pluck(:id)
        end
      end
    end
  end
end
