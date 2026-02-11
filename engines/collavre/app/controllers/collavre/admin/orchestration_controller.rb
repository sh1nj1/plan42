# frozen_string_literal: true

module Collavre
  module Admin
    class OrchestrationController < ApplicationController
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
        structure = {
          "arbitration" => { "global" => nil, "overrides" => [] },
          "scheduling" => { "global" => nil, "overrides" => [] }
        }

        policies.each do |policy|
          type = policy.policy_type
          next unless structure.key?(type)

          if policy.global?
            structure[type]["global"] = policy.config
          else
            structure[type]["overrides"] << {
              "scope_type" => policy.scope_type,
              "scope_id" => policy.scope_id,
              "config" => policy.config,
              "priority" => policy.priority
            }
          end
        end

        # Remove empty sections
        structure.each do |type, data|
          data.delete("global") if data["global"].nil?
          data.delete("overrides") if data["overrides"].empty?
        end
        structure.delete_if { |_, v| v.empty? }

        # Add defaults if empty
        if structure.empty?
          structure = default_policies_structure
        end

        structure.to_yaml
      end

      def default_policies_structure
        {
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
          }
        }
      end

      def validate_policies!(parsed)
        raise PolicyValidationError, t("admin.orchestration.invalid_format") unless parsed.is_a?(Hash)

        parsed.each do |type, data|
          unless %w[arbitration scheduling].include?(type)
            raise PolicyValidationError, t("admin.orchestration.unknown_policy_type", type: type)
          end

          unless data.is_a?(Hash)
            raise PolicyValidationError, t("admin.orchestration.invalid_policy_structure", type: type)
          end

          if data["global"].present? && !data["global"].is_a?(Hash)
            raise PolicyValidationError, t("admin.orchestration.invalid_global_config", type: type)
          end

          if data["overrides"].present?
            unless data["overrides"].is_a?(Array)
              raise PolicyValidationError, t("admin.orchestration.invalid_overrides", type: type)
            end

            data["overrides"].each_with_index do |override, idx|
              validate_override!(type, override, idx)
            end
          end
        end
      end

      def validate_override!(type, override, idx)
        unless override.is_a?(Hash)
          raise PolicyValidationError, t("admin.orchestration.invalid_override_format", type: type, index: idx)
        end

        unless %w[Creative Topic User].include?(override["scope_type"])
          raise PolicyValidationError, t("admin.orchestration.invalid_scope_type",
                                         type: type, index: idx, scope_type: override["scope_type"])
        end

        unless override["scope_id"].is_a?(Integer) && override["scope_id"].positive?
          raise PolicyValidationError, t("admin.orchestration.invalid_scope_id", type: type, index: idx)
        end

        unless override["config"].is_a?(Hash)
          raise PolicyValidationError, t("admin.orchestration.invalid_override_config", type: type, index: idx)
        end
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
