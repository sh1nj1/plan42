class AddOnboardingTimestampsToUsers < ActiveRecord::Migration[8.1]
  class MigrationUser < ActiveRecord::Base
    self.table_name = :users
  end

  def up
    add_column :users, :onboarding_seeded_at, :datetime
    add_column :users, :onboarding_completed_at, :datetime

    MigrationUser.reset_column_information
    MigrationUser.update_all(onboarding_seeded_at: Time.current)
  end

  def down
    remove_column :users, :onboarding_completed_at
    remove_column :users, :onboarding_seeded_at
  end
end
