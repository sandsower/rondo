import Config

config :phoenix, :json_library, Jason

config :rondo, RondoWeb.Endpoint,
  adapter: Bandit.PhoenixAdapter,
  url: [host: "localhost"],
  render_errors: [
    formats: [html: RondoWeb.ErrorHTML, json: RondoWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: Rondo.PubSub,
  live_view: [signing_salt: "rondo-live-view"],
  secret_key_base: String.duplicate("r", 64),
  check_origin: false,
  server: false
