# frozen_string_literal: true

module Collavre
  module Admin
    class OrchestrationController < ApplicationController
      EDITABLE_POLICY_TYPES = %w[matching arbitration scheduling collaboration].freeze

      before_action :require_system_admin!

      def show
        @policies_yaml = policies_to_yaml
      end

      def update
        yaml_content = params[:policies_yaml].to_s

        begin
          parsed = YAML.safe_load(yaml_content, permitted_classes: [ Symbol ])
          validate_policies!(parsed)
          apply_policies!(parsed)

          redirect_to admin_orchestration_path, notice: t("admin.orchestration.updated")
        rescue Psych::SyntaxError => e
          flash.now[:alert] = t("admin.orchestration.yaml_syntax_error", message: e.message)
          @policies_yaml = yaml_content
          render :show, status: :unprocessable_entity
        rescue PolicyValidationError => e
          flash.now[:alert] = e.message
          @policies_yaml = yaml_content
          render :show, status: :unprocessable_entity
        end
      end

      private

      class PolicyValidationError < StandardError; end

      def policies_to_yaml
        policies = OrchestratorPolicy.enabled.order(:policy_type, :scope_type, :priority)

        # Group by type for readable YAML structure
        structure = EDITABLE_POLICY_TYPES.index_with { { "global" => nil, "overrides" => [] } }

        policies.each do |policy|
          type = policy.policy_type
          next unless structure.key?(type)

          if policy.global?
            structure[type]["global"] = (structure[type]["global"] || {}).merge(policy.config)
          else
            structure[type]["overrides"] << {
              "scope_type" => policy.scope_type,
              "scope_id" => policy.scope_id,
              "config" => policy.config,
              "priority" => policy.priority
            }
          end
        end

        remove_empty_policy_sections!(structure)

        # Include matching for installations upgrading with existing policies.
        structure = default_policies_structure if structure.empty?
        structure["matching"] ||= default_policies_structure["matching"]

        structure.to_yaml
      end

      def remove_empty_policy_sections!(structure)
        structure.each_value do |data|
          data.delete("global") if data["global"].nil?
          data.delete("overrides") if data["overrides"].empty?
        end
        structure.delete_if { |_, data| data.empty? }
      end

      def default_policies_structure
        {
          "matching" => { "global" => { "workflow_routing" => "shadow" } },
          "arbitration" => {
            "global" => {
              "strategy" => "all",
              "max_responders" => nil
            }
          },
          "scheduling" => {
            "global" => {
              "max_concurrent_jobs" => 5,
              "daily_token_limit" => 100_000,
              "rate_limit_per_minute" => 20,
              "backoff_strategy" => "exponential",
              "topic_max_concurrent_jobs" => 1
            }
          },
          "collaboration" => {
            "global" => {
              "a2a_completion_instruction" => nil,
              "mention_rule" => nil
            }
          }
        }
      end

      def validate_policies!(parsed)
        raise PolicyValidationError, t("admin.orchestration.invalid_format") unless parsed.is_a?(Hash)

        parsed.each do |type, data|
          unless EDITABLE_POLICY_TYPES.include?(type)
            raise PolicyValidationError, t("admin.orchestration.unknown_policy_type", type: type)
          end

          unless data.is_a?(Hash)
            raise PolicyValidationError, t("admin.orchestration.invalid_policy_structure", type: type)
          end

          validate_global_config!(type, data["global"])
          validate_overrides!(type, data["overrides"]) unless data["overrides"].nil?
        end
      end

      def validate_global_config!(type, config)
        return if config.blank?

        unless config.is_a?(Hash)
          raise PolicyValidationError, t("admin.orchestration.invalid_global_config", type: type)
        end

        validate_workflow_routing!(type, config)
      end

      def validate_overrides!(type, overrides)
        unless overrides.is_a?(Array)
          raise PolicyValidationError, t("admin.orchestration.invalid_overrides", type: type)
        end

        overrides.each_with_index do |override, idx|
          validate_override!(type, override, idx)
        end
      end

      def validate_override!(type, override, idx)
        unless override.is_a?(Hash)
          raise PolicyValidationError, t("admin.orchestration.invalid_override_format", type: type, index: idx)
        end

        validate_scope_type!(type, override["scope_type"], idx)

        unless override["scope_id"].is_a?(Integer) && override["scope_id"].positive?
          raise PolicyValidationError, t("admin.orchestration.invalid_scope_id", type: type, index: idx)
        end

        unless override["config"].is_a?(Hash)
          raise PolicyValidationError, t("admin.orchestration.invalid_override_config", type: type, index: idx)
        end

        validate_workflow_routing!(type, override["config"])
      end

      def validate_scope_type!(type, scope_type, idx)
        scopes = type == "matching" ? %w[Creative Topic] : %w[Creative Topic User]
        return if scopes.include?(scope_type)

        raise PolicyValidationError, t("admin.orchestration.invalid_scope_type",
                                       type: type, index: idx, scope_type: scope_type, scopes: scopes.join(", "))
      end

      def validate_workflow_routing!(type, config)
        return unless type == "matching"

        config.stringify_keys!
        return unless config.key?("workflow_routing")
        return if Orchestration::PolicyResolver::MODES.include?(config["workflow_routing"])

        raise PolicyValidationError, t("admin.orchestration.invalid_workflow_routing")
      end

      def apply_policies!(parsed)
        OrchestratorPolicy.transaction do
          # Clear existing policies
          OrchestratorPolicy.delete_all

          parsed.each do |type, data|
            # Create global policy
            if data["global"].present?
              OrchestratorPolicy.create!(
                policy_type: type,
                scope_type: nil,
                scope_id: nil,
                config: data["global"],
                priority: 100,
                enabled: true
              )
            end

            # Create override policies
            data["overrides"]&.each_with_index do |override, idx|
              OrchestratorPolicy.create!(
                policy_type: type,
                scope_type: override["scope_type"],
                scope_id: override["scope_id"],
                config: override["config"],
                priority: override["priority"] || (50 - idx),
                enabled: true
              )
            end
          end
        end
      end
    end
  end
end
