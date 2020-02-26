defmodule Kantele.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  def start(_type, _args) do
    listener_config = [
      telnet: [
        port: 4444
      ],
      tls: [
        port: 4443,
        keyfile: Path.join(:code.priv_dir(:kantele), "certs/key.pem"),
        certfile: Path.join(:code.priv_dir(:kantele), "certs/cert.pem")
      ],
      foreman: [
        supervisor_name: Kantele.Character.Foreman.Supervisor,
        character_module: Kantele.Character,
        communication_module: Kantele.Communication,
        initial_controller: Kantele.Character.LoginController,
        presence_module: Kantele.Character.Presence,
        quit_view: {Kantele.Character.QuitView, "disconnected"}
      ]
    ]

    children = [
      {Kantele.Config, [name: Kantele.Config]},
      {Kantele.Character.Presence, []},
      {Kalevala.Character.Foreman.Supervisor, [name: Kantele.Character.Foreman.Supervisor]},
      {Kalevala.Telnet.Listener, listener_config},
      {Kantele.Communication, []},
      {Kantele.World, []},
      {Kantele.Telemetry, []}
    ]

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: Kantele.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
