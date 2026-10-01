class CreateCollavreTranslationTranslations < ActiveRecord::Migration[8.1]
  def change
    create_table :collavre_translation_translations do |t|
      t.references :translatable, polymorphic: true, null: false, index: false
      t.string :target_locale, null: false
      t.string :source_digest, null: false
      t.string :source_lang
      t.string :status, null: false, default: "pending"
      t.text :content
      t.string :llm_vendor
      t.string :llm_model
      t.timestamps
    end
    add_index :collavre_translation_translations,
      [ :translatable_type, :translatable_id, :target_locale, :source_digest ],
      unique: true, name: "index_translations_on_source_and_locale"
  end
end
