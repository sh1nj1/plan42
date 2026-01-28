# frozen_string_literal: true

module Collavre
  module Generators
    class InstallGenerator < Rails::Generators::Base
      source_root File.expand_path("templates", __dir__)

      desc "Install Collavre engine assets for jsbundling-rails"

      class_option :replace_build_script, type: :boolean, default: false,
        desc: "Replace script/build.cjs entirely (recommended for new projects)"

      def install_build_script
        build_script = Rails.root.join("script/build.cjs")

        if options[:replace_build_script] || !File.exist?(build_script)
          template "build.cjs.tt", "script/build.cjs"
          say_status :create, "script/build.cjs (with Collavre support)", :green
        else
          update_existing_build_script(build_script)
        end
      end

      def show_post_install
        say ""
        say "Collavre assets installed!", :green
        say ""
        say "The build script now automatically finds Collavre gem and includes its assets."
        say ""
        say "Stylesheets are automatically available via Propshaft."
        say "Add to your application.css if needed:"
        say "  @import 'collavre/creatives';"
        say "  @import 'collavre/comments_popup';"
        say "  @import 'collavre/dark_mode';"
        say ""
        say "Run 'npm run build' to build assets."
        say ""
      end

      private

      def update_existing_build_script(build_script)
        content = File.read(build_script)

        # Check if already installed
        if content.include?("collavre") || content.include?("COLLAVRE_GEM_PATH")
          say_status :skip, "Collavre already configured in build script", :yellow
          return
        end

        # Add gem path detection function after requires
        gem_path_function = <<~JS

          // Find Collavre gem path using bundler
          const { execSync } = require('child_process');
          function getCollavreGemPath() {
              if (process.env.COLLAVRE_GEM_PATH) return process.env.COLLAVRE_GEM_PATH;
              try {
                  const gemPath = execSync('bundle show collavre 2>/dev/null', { encoding: 'utf8' }).trim();
                  if (gemPath && !gemPath.includes('Could not find')) return gemPath;
              } catch (e) {}
              const localPath = path.join(process.cwd(), 'engines/collavre');
              if (require('fs').existsSync(localPath)) return localPath;
              return null;
          }
        JS

        # Add gem entry point discovery
        gem_discovery_code = <<~JS

          // Add Collavre gem entry points
          const collavreGemPath = getCollavreGemPath();
          if (collavreGemPath) {
              console.log(`[INFO] Including Collavre assets from: ${collavreGemPath}`);
              const collavreEntries = glob.sync(path.join(collavreGemPath, 'app/javascript/*.*'));
              collavreEntries.forEach(entry => {
                  const name = path.parse(entry).name;
                  if (!entryPoints[name]) entryPoints[name] = entry;
              });
          }
        JS

        # Insert function after requires
        if content.include?("const path = require('path');")
          content = content.sub(
            "const path = require('path');",
            "const path = require('path');#{gem_path_function}"
          )
        end

        # Insert discovery before the empty check
        if content.include?("if (Object.keys(entryPoints).length === 0)")
          content = content.sub(
            "if (Object.keys(entryPoints).length === 0)",
            "#{gem_discovery_code}\nif (Object.keys(entryPoints).length === 0)"
          )
          File.write(build_script, content)
          say_status :update, "script/build.cjs", :green
        else
          say_status :error, "Could not find insertion point in build script. Use --replace-build-script option.", :red
        end
      end
    end
  end
end
