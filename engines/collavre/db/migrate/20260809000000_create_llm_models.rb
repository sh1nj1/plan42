class CreateLlmModels < ActiveRecord::Migration[8.1]
  MAX_SUGGESTIONS = 100
  MAX_VENDOR_LENGTH = 255
  MAX_NAME_LENGTH = 255

  DEFAULT_MODELS = {
    "google" => [
      "gemini-3.1-flash-lite",
      "gemini-1.5-flash",
      "gemini-1.5-pro"
    ]
  }.freeze

  def up
    create_table :llm_models do |t|
      t.string :llm_vendor, null: false, limit: MAX_VENDOR_LENGTH
      t.string :name, null: false, limit: MAX_NAME_LENGTH
      t.references :created_by,
                   null: true,
                   foreign_key: { to_table: :users, on_delete: :nullify }
      t.timestamps
    end

    add_index :llm_models, [ :llm_vendor, :name ], unique: true

    llm_model_class = Class.new(ActiveRecord::Base) do
      self.table_name = "llm_models"
    end
    user_class = Class.new(ActiveRecord::Base) do
      self.table_name = "users"
    end

    models = DEFAULT_MODELS.flat_map do |vendor, names|
      names.map { |name| [ vendor, name ] }
    end
    models.concat(
      user_class.where.not(llm_vendor: [ nil, "" ])
                .where.not(llm_model: [ nil, "" ])
                .distinct
                .pluck(:llm_vendor, :llm_model)
    )

    models.each do |vendor, name|
      vendor = vendor.to_s.strip.downcase
      name = name.to_s.strip
      next if vendor.blank? || name.blank?
      next if vendor.length > MAX_VENDOR_LENGTH || name.length > MAX_NAME_LENGTH

      llm_model_class.find_or_create_by!(
        llm_vendor: vendor,
        name: name
      )
    end

    keep_ids = llm_model_class.order(updated_at: :desc, id: :desc)
                              .limit(MAX_SUGGESTIONS)
                              .select(:id)
    llm_model_class.where.not(id: keep_ids).delete_all
  end

  def down
    drop_table :llm_models
  end
end
