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
import "collavre_slack"
import "collavre_notion"
import "collavre_plan"
import "collavre_github"

// Host app specific modules
import "./firebase_config"
import "./timezone_detection"
import "./oauth_callback"
import "./doorkeeper_token"
