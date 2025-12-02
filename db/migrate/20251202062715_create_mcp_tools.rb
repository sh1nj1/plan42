class CreateMcpTools < ActiveRecord::Migration[8.1]
  def change
    create_table :mcp_tools do |t|
      t.references :creative, null: false, foreign_key: true
      t.string :name, null: false
      t.text :description
      t.text :source_code
      t.json :definition, default: {}
      t.string :checksum
      t.datetime :approved_at

      t.timestamps
    end
    add_index :mcp_tools, :name, unique: true
  end
end
