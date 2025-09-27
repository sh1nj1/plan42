class AddGithubGeminiPromptToCreatives < ActiveRecord::Migration[8.0]
  def change
    add_column :creatives, :github_gemini_prompt, :text
  end
end
