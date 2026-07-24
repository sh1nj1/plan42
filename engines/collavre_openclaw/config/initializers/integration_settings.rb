# Register collavre_openclaw integration setting keys with the central registry.
# Registered eagerly because `CollavreOpenclaw::Configuration#initialize` reads
# them at boot via `Collavre::IntegrationSettings.fetch`.
if defined?(Collavre::IntegrationSettings::Registry)
  registry = Collavre::IntegrationSettings::Registry.instance
  registry.register(:openclaw_open_timeout,        category: "openclaw", sensitive: false, requires_restart: true)
  registry.register(:openclaw_max_retries,         category: "openclaw", sensitive: false, requires_restart: true)
  registry.register(:openclaw_ws_idle_timeout,     category: "openclaw", sensitive: false, requires_restart: true)
  registry.register(:openclaw_ws_reconnect_max,    category: "openclaw", sensitive: false, requires_restart: true)
  registry.register(:openclaw_ws_reconnect_base,   category: "openclaw", sensitive: false, requires_restart: true)
  registry.register(:openclaw_ws_connect_timeout,  category: "openclaw", sensitive: false, requires_restart: true)
  registry.register(:openclaw_transport,           category: "openclaw", sensitive: false, requires_restart: true)
end
