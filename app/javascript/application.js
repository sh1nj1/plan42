import "@hotwired/turbo-rails"
import "./controllers"

import "trix"
import "@rails/actiontext"
import "./register_service_worker"
import * as ActionCable from "@rails/actioncable"
import "./trix_color_picker"

if (typeof window !== "undefined") {
  window.ActionCable = window.ActionCable || ActionCable
}

// Creative page modules
import "./creatives"
import "./plans_timeline"
import "./creative_row_swipe"
import "./mention_menu"
import "./export_to_markdown"
import "./components/creative_tree_row"
import "./github_integration"
import "./notion_integration"
