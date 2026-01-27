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

// Import Collavre engine modules (side-effect imports)
import "collavre"

// Host app specific modules
import "./firebase_config"
import "./github_integration"
import "./notion_integration"
import "./timezone_detection"
import "./oauth_callback"
import "./doorkeeper_token"
