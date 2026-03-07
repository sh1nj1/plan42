module Collavre
module Creatives
  class PlanTagger
    Result = Struct.new(:success?, :message, keyword_init: true)

    def initialize(plan_id:, creative_ids: [], user: nil)
      @plan = Plan.find_by(id: plan_id)
      @creative_ids = Array(creative_ids).map(&:presence).compact
      @user = user
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

    attr_reader :plan, :creative_ids, :user

    def creatives
      all_creatives = Creative.where(id: creative_ids)
      return all_creatives unless user

      # Scope to creatives the user has write permission for via creative_shares
      permitted_ids = all_creatives.joins(:creative_shares)
                                   .where(creative_shares: { user_id: user.id })
                                   .where("creative_shares.permission IN (?)", %w[write admin])
                                   .pluck(:id)
      # Also include creatives owned by the user
      owned_ids = all_creatives.where(user_id: user.id).pluck(:id)
      Creative.where(id: (permitted_ids + owned_ids).uniq)
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
end
