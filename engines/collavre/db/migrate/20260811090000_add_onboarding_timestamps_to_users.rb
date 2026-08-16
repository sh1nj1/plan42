class AddOnboardingTimestampsToUsers < ActiveRecord::Migration[8.1]
  def change
    add_column :users, :onboarding_seeded_at, :datetime
    add_column :users, :onboarding_completed_at, :datetime
  end
end
