defmodule Chat.Repo do
  use Ecto.Repo,
    otp_app: :sgiath_chat,
    adapter: Ecto.Adapters.Postgres
end
