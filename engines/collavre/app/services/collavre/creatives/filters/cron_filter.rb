# frozen_string_literal: true

module Collavre
module Creatives
  module Filters
    class CronFilter < BaseFilter
      def active?
        params[:has_cron].present?
      end

      def match
        creative_ids = Collavre::Crons::RecurringTaskIndex.new.creative_ids
        relation = params[:has_cron] == "true" ? scope.where(id: creative_ids) : scope.where.not(id: creative_ids)
        relation.pluck(:id)
      end
    end
  end
end
end
