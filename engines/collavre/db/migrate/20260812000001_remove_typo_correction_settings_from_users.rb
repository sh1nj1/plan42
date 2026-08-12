class RemoveTypoCorrectionSettingsFromUsers < ActiveRecord::Migration[8.0]
  def change
    remove_columns :users,
                   :typo_correction_enabled,
                   :typo_correction_threshold,
                   :typo_correction_on_soft_keyboard,
                   :typo_correction_on_voice,
                   :typo_correction_on_physical_keyboard,
                   :typo_correction_in_chat,
                   :typo_correction_in_editor
  end
end
