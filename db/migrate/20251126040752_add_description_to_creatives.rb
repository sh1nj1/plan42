class AddDescriptionToCreatives < ActiveRecord::Migration[8.1]
  def up
    add_column :creatives, :description, :text, limit: 4294967295

    # Data Migration
    say_with_time "Migrating ActionText to description column" do
      Creative.reset_column_information
      Creative.find_each do |creative|
        rich_text = ActionText::RichText.find_by(record_type: "Creative", record_id: creative.id, name: "description")
        if rich_text
          creative.update_column(:description, rich_text.body.to_html)
        end
      end
    end
  end

  def down
    remove_column :creatives, :description
  end
end
