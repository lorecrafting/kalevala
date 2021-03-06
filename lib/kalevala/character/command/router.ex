defmodule Kalevala.Character.Command.DynamicCommand do
  @moduledoc """
  A parsed dynamic command

  Generated from the `dynamic` command router DSL.
  """

  @doc """
  Called when parsing text from a user

  Options are passed through from the router.
  """
  @callback parse(text :: String.t(), options :: Keyword.t()) ::
              {:dynamic, function :: atom(), params :: map()} | :skip
end

defmodule Kalevala.Character.Command.ParsedCommand do
  @moduledoc """
  A parsed command
  """

  defstruct [:module, :function, :params]
end

defmodule Kalevala.Character.Command.Router do
  @moduledoc """
  Parse player input to known commands
  """

  alias Kalevala.Character.Command.ParsedCommand

  defmacro __using__(scope: scope) do
    {:__aliases__, _, top_module} = scope

    quote do
      import NimbleParsec
      import Kalevala.Character.Command.RouterMacros

      Module.register_attribute(__MODULE__, :parse_functions, accumulate: true)
      Module.register_attribute(__MODULE__, :aliases, accumulate: true)

      @before_compile Kalevala.Character.Command.Router

      @scope unquote(top_module)
    end
  end

  defmacro __before_compile__(env) do
    alias_functions =
      env.module
      |> Module.get_attribute(:aliases)
      |> Enum.map(fn {module, command, command_alias, fun, parse_fun} ->
        Kalevala.Character.Command.RouterMacros.generate_parse_function(
          command,
          command_alias,
          fun,
          parse_fun,
          module
        )
      end)

    quote do
      unquote(alias_functions)

      def call(conn, text) do
        unquote(__MODULE__).call(__MODULE__, conn, text)
      end

      @sorted_parse_functions Enum.reverse(@parse_functions)

      def parse(text) do
        unquote(__MODULE__).parse(__MODULE__, @sorted_parse_functions, text)
      end
    end
  end

  @doc false
  def call(module, conn, text) do
    case module.parse(text) do
      {:ok, %ParsedCommand{module: module, function: function, params: params}} ->
        conn = Map.put(conn, :params, params)
        apply(module, function, [conn, conn.params])

      {:error, :unknown} ->
        {:error, :unknown}
    end
  end

  @doc false
  def parse(module, parse_functions, text) do
    text = String.trim(text)

    parsed_command =
      Enum.find_value(parse_functions, fn command ->
        case apply(module, command, [text]) do
          {:ok, {module, function}, command, params} ->
            %Kalevala.Character.Command.ParsedCommand{
              module: module,
              function: function,
              params: process_params(params, command)
            }

          {:error, _error} ->
            false
        end
      end)

    case is_nil(parsed_command) do
      true ->
        {:error, :unknown}

      false ->
        {:ok, parsed_command}
    end
  end

  defp process_params(params, command) do
    params
    |> Enum.map(fn {key, value} ->
      {to_string(key), value}
    end)
    |> Enum.into(%{})
    |> Map.put("command", command)
  end
end

defmodule Kalevala.Character.Command.RouterMacros do
  @moduledoc """
  Set of macros to build a command router using NimbleParsec
  """

  @doc """
  Sets the `@module` tag for parse functions nested inside
  """
  defmacro module({:__aliases__, _meta, module}, do: block) do
    quote do
      @module @scope ++ unquote(module)
      unquote(block)
    end
  end

  @doc """
  Parse a new command

  `command` starts out the parse and any whitespace afterwards will be ignored
  """
  defmacro parse(command, fun, opts \\ [], parse_fun \\ nil) do
    {opts, parse_fun} = opts_vs_parse(opts, parse_fun)
    aliases = Keyword.get(opts, :aliases, [])
    parse_fun = parse_fun || (&__MODULE__.default_parse_function/1)

    aliases =
      Enum.map(aliases, fn command_alias ->
        quote do
          scope = [:"Elixir" | @module]
          module = String.to_atom(Enum.join(scope, "."))

          @aliases {module, unquote(command), unquote(command_alias), unquote(fun),
                    unquote(parse_fun)}
        end
      end)

    [
      generate_parse_function(command, command, fun, parse_fun),
      aliases
    ]
  end

  def generate_parse_function(command, command_alias, fun, parse_fun, module \\ nil) do
    internal_function_name = :"parsep_#{command_alias}_#{fun}"
    function_name = :"parse_#{command_alias}_#{fun}"

    module =
      module ||
        quote do
          scope = [:"Elixir" | @module]
          unquote(module) || String.to_atom(Enum.join(scope, "."))
        end

    quote do
      defparsecp(
        unquote(internal_function_name),
        unquote(parse_fun).(command(unquote(command_alias)))
      )

      @parse_functions unquote(function_name)

      def unquote(function_name)(text) do
        unquote(__MODULE__).parse_text(
          unquote(module),
          unquote(fun),
          unquote(command),
          unquote(internal_function_name)(text)
        )
      end
    end
  end

  defp opts_vs_parse(opts = {:fn, _, _}, _parse_fun) do
    {[], opts}
  end

  defp opts_vs_parse(opts, parse_fun), do: {opts, parse_fun}

  def parse_text(module, fun, command, {:ok, parsed, _leftover, _unknown1, _unknown2, _unknown3}) do
    {:ok, {module, fun}, command, parsed}
  end

  def parse_text(_module, _fun, _command, {:error, error, _leftover, _u1, _u2, _u3}) do
    {:error, error}
  end

  @doc false
  def default_parse_function(command), do: command

  @doc """
  Handle dynamic parsing

  This runs the `parse/2` function on the given module at runtime. This enables
  parsing things against runtime only data.
  """
  defmacro dynamic({:__aliases__, _meta, module}, command, arguments) do
    function_name = :"parse_dynamic_#{command}"

    quote do
      @parse_functions unquote(function_name)

      def unquote(function_name)(text) do
        scope = [:"Elixir" | @scope] ++ unquote(module)
        module = String.to_atom(Enum.join(scope, "."))

        unquote(__MODULE__).parse_dynamic_text(module, unquote(arguments), text)
      end
    end
  end

  def parse_dynamic_text(module, arguments, text) do
    case module.parse(text, arguments) do
      {:dynamic, function, params} ->
        {:ok, {module, function}, params}

      :skip ->
        {:error, :unknown}
    end
  end

  @doc """
  Wraps NimbleParsec macros to generate a tagged command
  """
  defmacro command(command) do
    quote do
      string(unquote(command))
      |> label("#{unquote(command)} command")
      |> unwrap_and_tag(:command)
    end
  end

  @doc """
  Wraps NimbleParsec macros to allow for grabbing spaces

  Grabs between other pieces of the command
  """
  defmacro spaces(parsec) do
    quote do
      unquote(parsec)
      |> ignore(utf8_string([?\s], min: 1))
      |> label("spaces")
    end
  end

  @doc """
  Wraps NimbleParsec macros to generate a tagged word

  Words are codepoints that don't include a space, or everything inside of quotes.

  Both of the following count as a word:
  - villager
  - "town crier"
  """
  defmacro word(parsec, tag) do
    quote do
      unquote(parsec)
      |> concat(
        choice([
          ignore(string("\""))
          |> utf8_string([not: ?"], min: 1)
          |> ignore(string("\""))
          |> reduce({Enum, :join, [""]}),
          utf8_string([not: ?\s, not: ?"], min: 1)
        ])
        |> unwrap_and_tag(unquote(tag))
        |> label("#{unquote(tag)} word")
      )
    end
  end

  defmacro symbol(parsec \\ NimbleParsec.empty(), character) do
    quote do
      unquote(parsec)
      |> ignore(string(unquote(character)))
    end
  end

  @doc """
  Wraps NimbleParsec macros to generate tagged text

  This grabs as much as it can
  """
  defmacro text(parsec, tag) do
    quote do
      unquote(parsec)
      |> concat(unwrap_and_tag(utf8_string([], min: 1), unquote(tag)))
    end
  end
end
