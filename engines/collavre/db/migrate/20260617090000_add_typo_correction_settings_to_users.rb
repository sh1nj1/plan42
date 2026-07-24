class AddTypoCorrectionSettingsToUsers < ActiveRecord::Migration[8.0]
  def change
    # Master switch + auto-apply confidence threshold (0-100).
    add_column :users, :typo_correction_enabled, :boolean, default: true, null: false
    add_column :users, :typo_correction_threshold, :integer, default: 80, null: false

    # Typing-device gating (2D gating, dimension 1). Soft keyboard / voice default
    # on, physical (BT/wired) keyboard default off — each independently toggleable.
    add_column :users, :typo_correction_on_soft_keyboard, :boolean, default: true, null: false
    add_column :users, :typo_correction_on_voice, :boolean, default: true, null: false
    add_column :users, :typo_correction_on_physical_keyboard, :boolean, default: false, null: false

    # Input-location gating (2D gating, dimension 2). Chat message input default on,
    # inline Lexical/markdown editor default off — each independently toggleable.
    add_column :users, :typo_correction_in_chat, :boolean, default: true, null: false
    add_column :users, :typo_correction_in_editor, :boolean, default: false, null: false
  end
end
