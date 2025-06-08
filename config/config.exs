import Config

config :sgiath_chat, :scopes,
  user: [
    default: true,
    module: Chat.Accounts.Scope,
    assign_key: :current_scope,
    access_path: [:user, :id],
    schema_key: :user_id,
    schema_type: :binary_id,
    schema_table: :users,
    test_data_fixture: Chat.AccountsFixtures,
    test_login_helper: :register_and_log_in_user
  ]

# Configure Mix tasks and generators
config :sgiath_chat,
  namespace: Chat,
  ecto_repos: [Chat.Repo]

# Configures the mailer
#
# By default it uses the "Local" adapter which stores the emails
# locally. You can see the emails in your browser, at "/dev/mailbox".
#
# For production it's recommended to configure a different adapter
# at the `config/runtime.exs`.
config :sgiath_chat, Chat.Mailer, adapter: Swoosh.Adapters.Local

config :sgiath_chat_web,
  namespace: ChatWeb,
  ecto_repos: [Chat.Repo],
  generators: [context_app: :sgiath_chat, binary_id: true]

# Configures the endpoint
config :sgiath_chat_web, ChatWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [html: ChatWeb.ErrorHTML, json: ChatWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: Chat.PubSub,
  live_view: [signing_salt: "mhpYrHFE"]

# Configure esbuild (the version is required)
config :esbuild,
  version: "0.25.5",
  sgiath_chat_web: [
    args:
      ~w(js/app.js --bundle --target=es2022 --outdir=../priv/static/assets/js --external:/fonts/* --external:/images/*),
    cd: Path.expand("../apps/sgiath_chat_web/assets", __DIR__),
    env: %{"NODE_PATH" => Path.expand("../deps", __DIR__)}
  ]

# Configure tailwind (the version is required)
config :tailwind,
  version: "4.1.8",
  sgiath_chat_web: [
    args: ~w(
      --input=assets/css/app.css
      --output=priv/static/assets/css/app.css
    ),
    cd: Path.expand("../apps/sgiath_chat_web", __DIR__)
  ]

# Configures Elixir's Logger
config :logger, :default_formatter,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

config :phoenix, :json_library, JSON

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"
