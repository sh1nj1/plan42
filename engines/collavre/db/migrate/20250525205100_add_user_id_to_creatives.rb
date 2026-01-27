class AddUserIdToCreatives < ActiveRecord::Migration[8.0]
  def up
    add_reference :creatives, :user, foreign_key: true, null: true
    # No NOT NULL constraint; user_id can remain null
  end

  def down
    remove_reference :creatives, :user, foreign_key: true
  end
end
