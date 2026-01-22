// Collavre Engine - Main Entry Point
// This file imports all Collavre modules and exports the controller registration function

// Import side-effect modules
import "./modules/creatives"
import "./modules/plans_timeline"
import "./modules/creative_row_swipe"
import "./modules/mention_menu"
import "./modules/export_to_markdown"
import "./modules/plans_menu"
import "./modules/inbox_panel"
import "./modules/creative_guide"
import "./modules/share_modal"
import "./modules/share_user_popup"
import "./modules/creative_row_editor"
import "./modules/slide_view"

// Import components
import "./components/creative_tree_row"

// Import and re-export lib utilities
import "./lib/apply_lexical_styles"
import "./lib/turbo_stream_actions"

// Export controller registration
export { registerControllers } from "./controllers"
