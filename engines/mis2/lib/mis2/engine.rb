module Mis2
  class Engine < ::Rails::Engine
    isolate_namespace Mis2

    # Mount engine at /mis2
    initializer "mis2.mount_engine" do |app|
      app.routes.append do
        mount Mis2::Engine => "/mis2"
      end
    end
  end
end
