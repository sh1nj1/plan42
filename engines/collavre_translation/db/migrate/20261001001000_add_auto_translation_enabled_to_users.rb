class AddAutoTranslationEnabledToUsers < ActiveRecord::Migration[8.0]
  def change
    add_column :users, :auto_translation_enabled, :boolean, default: true, null: false
  end
end
