import "./cable_config"
import "@hotwired/turbo-rails"
import "./controllers"

import "@rails/actiontext"
import * as ActiveStorage from "@rails/activestorage"
import "./register_service_worker"
import * as ActionCable from "@rails/actioncable"

if (typeof window !== "undefined") {
  window.ActiveStorage = window.ActiveStorage || ActiveStorage
}

ActiveStorage.start()

// Creative page modules
import "./creatives"
import "./plans_timeline"
import "./creative_row_swipe"
import "./mention_menu"
import "./export_to_markdown"
import "./components/creative_tree_row"
import "./github_integration"
import "./notion_integration"
import "./lib/apply_lexical_styles"
import "./lib/turbo_stream_actions"
import "./share_user_popup"

