require_relative "../../lib/middleware/home_path_rewriter"

Rails.application.config.middleware.use HomePathRewriter
