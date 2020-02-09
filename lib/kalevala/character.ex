defmodule Kalevala.Character do
  @moduledoc """
  Character struct

  Common data that all characters will have
  """

  defstruct [:id, :pid, :room_id, :name, :status, :description, meta: %{}]
end
