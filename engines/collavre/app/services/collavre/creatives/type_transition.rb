# frozen_string_literal: true

module Collavre
  module Creatives
    class TypeTransition
      MAX_LENGTH = 64
      PROTECTED = %w[inbox workflow_rule].freeze

      def initialize(creative, input, user)
        @creative, @input, @user = creative, input, user
      end

      def apply
        return error(:invalid) unless valid_input?

        target = @input.unicode_normalize(:nfkc).strip.gsub(/[[:space:]]+/, " ").downcase
        return error(:invalid) if target.length > MAX_LENGTH
        return if target == @creative.creative_type
        return error(:protected) if PROTECTED.include?(target) || PROTECTED.include?(@creative.creative_type)
        return error(:data_present) if workflow_data?
        return error(:admin_required) if workflow_boundary?(target) && !admin?
        return error(:read_only) if @creative.read_only_source? || @creative.archived_at.present?

        @creative.data = (@creative.data || {}).except("kind")
        @creative.data["kind"] = target unless target.empty?
      end

      private

      def valid_input?
        @input.is_a?(String) && @input.valid_encoding? && !@input.match?(/[[:cntrl:]]/)
      end

      def workflow_data?
        (@creative.data || {}).key?("workflow") || (@creative.data || {}).key?("workflow_rule") ||
          @creative.children.where("data->>'kind' = ?", "workflow_rule").exists?
      end

      def workflow_boundary?(target)
        target == "workflow" || @creative.workflow?
      end

      def admin?
        scope = @creative.persisted? ? @creative : @creative.parent
        scope ? scope.has_permission?(@user, :admin) : @creative.user == @user
      end

      def error(key)
        @creative.errors.add(:base, I18n.t("collavre.creatives.types.errors.#{key}"))
      end
    end
  end
end
