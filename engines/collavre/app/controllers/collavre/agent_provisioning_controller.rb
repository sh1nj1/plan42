# frozen_string_literal: true

module Collavre
  class AgentProvisioningController < ActionController::Base
    SKILL_NAME = "collavre"
    CONFIG_NAME = "collavre"
    CACHE_CONTROL = "public, max-age=31536000, immutable"

    rate_limit to: 60, within: 1.minute, only: :manifest

    def manifest
      response.headers["Cache-Control"] = "private, no-store"
      workspace = find_workspace!
      skill = Collavre::AgentProvisioning::Archive.collavre_skill
      config = Collavre::AgentProvisioning::Archive.workspace_config(workspace, base_url: request.base_url)

      render json: {
        schema: "agent-provisioning/v1",
        items: [
          {
            type: "skill",
            name: SKILL_NAME,
            url: absolute_url(agent_provision_skill_path(sha256: digest(skill))),
            sha256: digest(skill)
          },
          {
            type: "config",
            name: CONFIG_NAME,
            url: absolute_url(agent_provision_config_path(
              agent_id: workspace.agent_id,
              token: workspace.manifest_token,
              sha256: digest(config)
            )),
            sha256: digest(config)
          }
        ]
      }
    end

    def skill
      bytes = Collavre::AgentProvisioning::Archive.collavre_skill
      return head :not_found unless digest_matches?(bytes)

      send_archive(bytes, "collavre.tar.gz")
    end

    def config_archive
      workspace = find_workspace!
      bytes = Collavre::AgentProvisioning::Archive.workspace_config(workspace, base_url: request.base_url)
      return head :not_found unless digest_matches?(bytes)

      send_archive(bytes, "collavre-config.tar.gz", cache_control: "private, no-store")
    end

    private

    def find_workspace!
      Collavre::AgentWorkspace.find_by!(agent_id: params[:agent_id], manifest_token: params[:token])
    end

    def digest(bytes)
      Collavre::AgentProvisioning::Archive.sha256(bytes)
    end

    def absolute_url(path)
      "#{request.base_url}#{path}"
    end

    def digest_matches?(bytes)
      supplied = params[:sha256].to_s
      supplied.bytesize == 64 && ActiveSupport::SecurityUtils.secure_compare(supplied, digest(bytes))
    end

    def send_archive(bytes, filename, cache_control: CACHE_CONTROL)
      response.headers["Cache-Control"] = cache_control
      send_data bytes, type: "application/gzip", disposition: "inline", filename: filename
    end
  end
end
