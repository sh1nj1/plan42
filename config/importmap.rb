# Pin npm packages by running ./bin/importmap

pin "application"
pin "@hotwired/turbo-rails", to: "turbo.min.js"
pin "@hotwired/stimulus", to: "stimulus.min.js"
pin "@hotwired/stimulus-loading", to: "stimulus-loading.js"
pin_all_from "app/javascript/controllers", under: "controllers"
pin "trix"
pin "@rails/actiontext", to: "actiontext.esm.js"
pin "register_service_worker"
pin "firebase/app", to: "https://www.gstatic.com/firebasejs/10.11.1/firebase-app.js"
pin "firebase/messaging", to: "https://www.gstatic.com/firebasejs/10.11.1/firebase-messaging.js"
