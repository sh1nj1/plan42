# Where the mock Notion server listens, for both halves of the pair.
#
# NOTION_MOCK_PORT moves the server (script/mock_server.rb), so a client default
# of "localhost:4568" is only right until a developer takes that documented
# escape from a port conflict — after which every auto-mocked API call dials a
# port nothing is listening on. The port has to be read from one place by both,
# and that place cannot need Rails: the mock server is also runnable as a plain
# `ruby engines/collavre_notion/script/mock_server.rb`.
module CollavreNotion
  MOCK_SERVER_DEFAULT_PORT = 4568

  def self.mock_server_port
    Integer(ENV.fetch("NOTION_MOCK_PORT", MOCK_SERVER_DEFAULT_PORT))
  end

  # The mock speaks the same /v1 paths as api.notion.com.
  def self.mock_server_base_url
    "http://localhost:#{mock_server_port}/v1"
  end
end
