module Creatives
  class PlanTagger
    Result = Struct.new(:success?, :message, keyword_init: true)

    def initialize(plan_id:, creative_ids: [])
      @plan = Plan.find_by(id: plan_id)
      @creative_ids = Array(creative_ids).map(&:presence).compact
    end

    def apply
      return failure("Please select a plan and at least one creative.") unless valid?

      creatives.find_each do |creative|
        creative.tags.find_or_create_by(label: plan, creative_id: creative.id)
      end

      success("Plan tags applied to selected creatives.")
    end

    def remove
      return failure("Please select a plan and at least one creative.") unless valid?

      creatives.find_each do |creative|
        tag = creative.tags.find_by(label: plan, creative_id: creative.id)
        tag&.destroy
      end

      success("Plan tag removed from selected creatives.")
    end

    private

    attr_reader :plan, :creative_ids

    def creatives
      Creative.where(id: creative_ids)
    end

    def valid?
      plan.present? && creative_ids.any?
    end

    def success(message)
      Result.new(success?: true, message: message)
    end

    def failure(message)
      Result.new(success?: false, message: message)
    end
  end
end
