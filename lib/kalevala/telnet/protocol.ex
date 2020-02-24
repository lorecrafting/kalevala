defmodule Kalevala.Telnet.Protocol do
  @moduledoc """
  ranch protocol for handling telnet connection
  """

  alias Kalevala.Character.Conn.Event
  alias Kalevala.Character.Conn.Lines
  alias Kalevala.Character.Conn.Option
  alias Kalevala.Character.Actor
  alias Telnet.Options

  require Logger

  @behaviour :ranch_protocol

  @impl true
  def start_link(ref, _socket, transport, opts) do
    # Use the special start link to get around a ranch deadlock
    # on `:ranch.handshake/1`
    pid = :proc_lib.spawn_link(__MODULE__, :init, [ref, transport, opts])
    {:ok, pid}
  end

  @doc false
  def init(ref, transport, actor_options) do
    # See deadlock comment above
    {:ok, socket} = :ranch.handshake(ref)
    :ok = transport.setopts(socket, active: true)
    send(self(), :init)

    state = %{
      socket: socket,
      transport: transport,
      buffer: <<>>,
      actor_pid: nil,
      actor_options: actor_options,
      options: %{
        newline: false
      }
    }

    :gen_server.enter_loop(__MODULE__, [], state)
  end

  def handle_info(:init, state) do
    {:ok, actor_pid} = Actor.start(self(), state.actor_options)
    state = Map.put(state, :actor_pid, actor_pid)
    {:noreply, state, {:continue, :initial_iacs}}
  end

  def handle_info({:tcp, _socket, data}, state) do
    process_data(state, data)
  end

  def handle_info({:ssl, _socket, data}, state) do
    process_data(state, data)
  end

  def handle_info({:tcp_closed, _socket}, state) do
    handle_info(:terminate, state)
  end

  def handle_info({:ssl_closed, _socket}, state) do
    handle_info(:terminate, state)
  end

  def handle_info(:terminate, state) do
    Logger.info("Session terminating")
    send(state.actor_pid, :terminate)
    {:stop, :normal, state}
  end

  def handle_info({:send, data}, state) do
    data = List.wrap(data)

    state =
      Enum.reduce(data, state, fn data, state ->
        push(state, data)
      end)

    {:noreply, state}
  end

  def handle_continue(:initial_iacs, state) do
    # WILL GMCP
    state.transport.send(state.socket, <<255, 251, 201>>)
    # DO OAuth
    state.transport.send(state.socket, <<255, 253, 165>>)
    # DO NEW-ENVIRON
    state.transport.send(state.socket, <<255, 253, 39>>)
    {:noreply, state}
  end

  defp push(state, output = %Event{}) do
    data = <<255, 250, 201>>
    data = data <> output.topic <> " "
    data = data <> Jason.encode!(output.data)
    data = data <> <<255, 240>>

    state.transport.send(state.socket, data)
    state
  end

  defp push(state, output = %Lines{}) do
    push_text(state, output.data)
    if output.go_ahead, do: state.transport.send(state.socket, <<255, 249>>)
    update_newline(state, output.newline)
  end

  defp push(state, output = %Option{name: :echo}) do
    case output.value do
      true ->
        state.transport.send(state.socket, <<255, 251, 1>>)

      false ->
        state.transport.send(state.socket, <<255, 252, 1>>)
    end

    state
  end

  defp push_text(state, text) do
    case state.options.newline do
      true ->
        state.transport.send(state.socket, ["\n", text])

      false ->
        state.transport.send(state.socket, text)
    end
  end

  defp process_data(state, data) do
    {options, string, buffer} = Options.parse(state.buffer <> data)
    state = %{state | buffer: buffer}

    Enum.each(options, fn option ->
      send(state.actor_pid, {:recv, :option, option})
    end)

    send(state.actor_pid, {:recv, :text, string})

    {:noreply, update_newline(state, String.length(string) == 0)}
  end

  defp update_newline(state, status) do
    %{state | options: %{state.options | newline: status}}
  end
end
