class SeedCodexCustomProxyLlmModels < ActiveRecord::Migration[8.1]
  MAX_SUGGESTIONS = 100
  DEFAULT_MODELS = [
    "paperclip/codex_custom/anthropic/claude-sonnet-4.5",
    "paperclip/codex_custom/openai/gpt-5"
  ].freeze

  def up
    DEFAULT_MODELS.each do |name|
      model = llm_model_class.find_or_create_by!(llm_vendor: "cli_proxy", name:)
      model.touch unless model.previously_new_record?
    end

    keep_ids = llm_model_class.order(updated_at: :desc, id: :desc).limit(MAX_SUGGESTIONS).select(:id)
    llm_model_class.where.not(id: keep_ids).delete_all
  end

  # Keep shared, user-created model suggestions intact if this data migration is rolled back.
  def down; end

  private

  def llm_model_class
    @llm_model_class ||= Class.new(ActiveRecord::Base) do
      self.table_name = "llm_models"
    end
  end
end
