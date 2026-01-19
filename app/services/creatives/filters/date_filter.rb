module Creatives
  module Filters
    class DateFilter < BaseFilter
      def active?
        params[:due_before].present? ||
          params[:due_after].present? ||
          params[:has_due_date].present?
      end

      def match
        # Label의 target_date 기반 필터링
        if params[:has_due_date] == "false"
          # target_date가 없는 creative
          # 1. creatives with labels that have no target_date
          # 2. creatives with no tags at all
          with_null_date = scope.left_joins(tags: :label)
                                .where(labels: { target_date: nil })
                                .pluck(:id)
          without_tags = scope.left_joins(:tags)
                              .where(tags: { id: nil })
                              .pluck(:id)
          return (with_null_date + without_tags).uniq
        end

        result = scope.joins(:tags)
                      .joins("INNER JOIN labels ON tags.label_id = labels.id")

        if params[:has_due_date] == "true"
          result = result.where.not(labels: { target_date: nil })
        end

        if params[:due_before].present?
          result = result.where("labels.target_date <= ?", Date.parse(params[:due_before]))
        end

        if params[:due_after].present?
          result = result.where("labels.target_date >= ?", Date.parse(params[:due_after]))
        end

        result.distinct.pluck(:id)
      end
    end
  end
end
