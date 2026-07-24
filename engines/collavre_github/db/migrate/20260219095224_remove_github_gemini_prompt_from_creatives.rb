class RemoveGithubGeminiPromptFromCreatives < ActiveRecord::Migration[8.1]
  def change
    remove_column :creatives, :github_gemini_prompt, :text
  end
end
