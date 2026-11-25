class AddRunOptionsToCommentVersions < ActiveRecord::Migration[8.0]
  def change
    add_column :comment_versions, :agent_run_options, :json
  end
end
