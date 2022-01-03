defmodule Double do
  @moduledoc """
  Double builds on-the-fly injectable dependencies for your tests.
  It does NOT override behavior of existing modules or functions.
  Double uses Elixir's built-in language features such as pattern matching and message passing to
  give you everything you would normally need a complex mocking tool for.
  """

  alias Double.{FuncList, Registry}
  use GenServer

  defdelegate assert_called(mfargs), to: Double.Assertions

  @default_options [verify: true, send_stubbed_module: false]

  @type allow_option ::
          {:with, [...]}
          | {:returns, any}
          | {:raises,
             String.t()
             | {atom, String.t()}}
  @type double_option :: {:verify, true | false}

  # TODO - rework or remove this
  defmacro defmock(mock_name, for: source) do
    mock_name = Macro.expand(mock_name, __CALLER__)
    source = Macro.expand(source, __CALLER__)

    unless Code.ensure_compiled(source) == {:module, source} do
      raise(ArgumentError, "module #{inspect(source)} either does not exist or is not loaded")
    end

    func_defs =
      for {func_name, arity} <- nonprotected_functions(source) do
        args = Macro.generate_arguments(arity, source)

        quote do
          def unquote(func_name)(unquote_splicing(args)) do
            IO.puts("Hello from #{unquote(func_name)}")

            Double.Listener.record(
              {unquote(mock_name), unquote(func_name), [unquote_splicing(args)]}
            )

            # DoubleAgent.Handoff.call(
            #   {unquote(source), unquote(func_name), [unquote_splicing(args)]}
            # )

            apply(unquote(source), unquote(func_name), [unquote_splicing(args)])
          end
        end
      end

    quote do
      defmodule unquote(mock_name) do
        unquote(func_defs)
      end
    end
  end

  # TODO - decide what to do with this
  defmacro defshim(alias, opts \\ []) do
    source = Keyword.fetch!(opts, :for)

    env = __CALLER__
    expanded = Macro.expand(alias, env)
    source = Macro.expand(source, env)

    unless Code.ensure_compiled(source) == {:module, source} do
      raise(ArgumentError, "module #{inspect(source)} either does not exist or is not loaded")
    end

    func_defs = generate_function_defs(expanded, source)

    quoted_use =
      quote do
        use Double.Shim, for: unquote(source)
      end

    Module.create(expanded, [quoted_use | func_defs], Macro.Env.location(__ENV__))
  end

  defp generate_function_defs(name, source, other_funcs \\ []) do
    funcs = Enum.uniq(nonprotected_functions(source) ++ other_funcs)

    for {func_name, arity} <- funcs do
      generate_function_def(name, func_name, arity)
    end
  end

  defp generate_function_def(mod, func_name, arity) do
    args = Macro.generate_arguments(arity, mod)

    quote do
      def unquote(func_name)(unquote_splicing(args)) do
        __handle_double_call__({unquote(mod), unquote(func_name), [unquote_splicing(args)]})
      end
    end
  end

  defp nonprotected_functions(mod) do
    mod.module_info(:functions)
    |> Enum.reject(fn {k, _} ->
      [:__info__, :module_info] |> Enum.member?(k) ||
        String.starts_with?("#{k}", "_") ||
        String.starts_with?("#{k}", "-")
    end)
  end

  def spy(target) do
    target
    |> nonprotected_functions()
    |> Enum.reduce(stub(target), fn {func, arity}, dbl ->
      args = Macro.generate_arguments(arity, target)

      {f, _} =
        quote do
          fn unquote_splicing(args) ->
            apply(unquote(target), unquote(func), [unquote_splicing(args)])
          end
        end
        |> Code.eval_quoted()

      stub(dbl, func, f)
    end)
  end

  @spec stub(atom, atom, function) :: atom
  def stub(dbl), do: double(dbl, Keyword.put(@default_options, :send_stubbed_module, true))

  def stub(dbl, function_name, func) do
    double_id = Atom.to_string(dbl)
    pid = Registry.whereis_double(double_id)

    dbl =
      case pid do
        :undefined -> stub(dbl)
        _ -> dbl
      end

    dbl
    |> verify_mod_double(function_name, func)
    |> verify_struct_double(function_name)
    |> do_allow(function_name, func)
  end

  @spec double :: map
  @spec double(struct, [double_option]) :: struct
  @spec double(atom, [double_option]) :: atom
  @doc """
  Returns a map that can be used to setup stubbed functions.
  """
  def double, do: double(%{})

  @doc """
  Same as double/0 but can return structs and modules too
  """
  def double(source, opts \\ @default_options) do
    opts = Enum.into(opts, %{})
    test_pid = self()
    {:ok, pid} = GenServer.start_link(__MODULE__, [])

    double_id =
      case {is_atom(source), Map.has_key?(opts, :name)} do
        {true, true} ->
          # TODO - determine if there are any atoms we don't want to attempt to redefine
          opts[:name] |> Atom.to_string()

        {true, _} ->
          source_name =
            source
            |> Atom.to_string()
            |> String.split(".")
            |> List.last()

          Module.concat(source_name, "Double#{:erlang.unique_integer([:positive])}")
          |> Atom.to_string()

        {false, _} ->
          :sha
          |> :crypto.hash(inspect(pid))
          |> Base.encode16()
          |> String.downcase()
      end

    Registry.register_double(double_id, pid, test_pid, source, opts)

    case is_atom(source) do
      true -> double_id |> String.to_atom()
      false -> Map.put(source, :_double_id, double_id)
    end
  end

  @doc """
  Adds a stubbed function to the given map, struct, or module.
  Structs will fail if they are missing the key given for function_name.
  Modules will fail if the function is not defined.
  """
  @spec allow(any, atom, function | [allow_option]) :: struct | map | atom
  def allow(dbl, function_name) when is_atom(function_name),
    do: allow(dbl, function_name, with: [])

  def allow(dbl, function_name, func_opts) when is_list(func_opts) do
    return_values =
      Enum.reduce(func_opts, [], fn {k, v}, acc ->
        if k == :returns, do: acc ++ [v], else: acc
      end)

    return_values = if return_values == [], do: [nil], else: return_values

    option_sets =
      return_values
      |> Enum.reduce([], fn return_value, acc ->
        append_opts =
          func_opts
          |> Keyword.take([:with, :raises])
          |> Keyword.put(:returns, return_value)

        acc ++ [append_opts]
      end)

    option_sets
    |> Enum.reduce(dbl, fn opts, acc ->
      {func, _} = create_function_from_opts(opts)
      allow(acc, function_name, func)
    end)
  end

  def allow(dbl, function_name, func) when is_function(func) do
    dbl
    |> verify_mod_double(function_name, func)
    |> verify_struct_double(function_name)
    |> do_allow(function_name, func)
  end

  @doc """
  Clears stubbed functions from a double. By passing no arguments (or nil) all functions will be
  cleared. A single function name (atom) or a list of function names can also be given.
  """
  @spec clear(any, atom | list) :: struct | map | atom
  def clear(dbl, function_name \\ nil) do
    double_id = if is_atom(dbl), do: Atom.to_string(dbl), else: dbl._double_id
    pid = Registry.whereis_double(double_id)
    GenServer.call(pid, {:clear, dbl, function_name})
  end

  @doc false
  def func_list(pid) do
    GenServer.call(pid, :func_list)
  end

  defp do_allow(dbl, function_name, func) do
    double_id = if is_atom(dbl), do: Atom.to_string(dbl), else: dbl._double_id
    pid = Registry.whereis_double(double_id)
    GenServer.call(pid, {:allow, dbl, function_name, func}, :infinity)
  end

  defp verify_mod_double(dbl, function_name, func) when is_atom(dbl) do
    double_opts = Registry.opts_for("#{dbl}")

    if double_opts[:verify] do
      source = Registry.source_for("#{dbl}")
      source_functions = source.module_info(:functions)

      source_functions =
        if source_functions[:__info__] do
          source_functions ++ source.__info__(:macros)
        else
          source_functions
        end

      source_functions =
        if source_functions[:behaviour_info] do
          source_functions ++ source.behaviour_info(:callbacks)
        else
          source_functions
        end

      stub_arity = :erlang.fun_info(func)[:arity]

      matching_function =
        Enum.find(source_functions, fn {k, v} ->
          k == function_name && v == stub_arity
        end)

      if matching_function == nil do
        raise VerifyingDoubleError,
          message:
            "The function '#{function_name}/#{stub_arity}' is not defined in #{inspect(dbl)}"
      end
    end

    dbl
  end

  defp verify_mod_double(dbl, _, _), do: dbl

  defp verify_struct_double(%{__struct__: _} = dbl, function_name) do
    if Map.has_key?(dbl, function_name) do
      dbl
    else
      struct_key_error(dbl, function_name)
    end
  end

  defp verify_struct_double(dbl, _), do: dbl

  # SERVER

  def init([]) do
    {:ok, pid} = GenServer.start_link(FuncList, [])
    {:ok, %{func_list: pid}}
  end

  @doc false
  def handle_call(:func_list, _from, state) do
    {:reply, state.func_list, state}
  end

  @doc false
  def handle_call({:allow, dbl, function_name, func}, _from, state) do
    FuncList.push(state.func_list, function_name, func)

    dbl =
      case is_atom(dbl) do
        true ->
          stub_module(dbl, state)
          dbl

        false ->
          dbl
          |> Map.put(
            function_name,
            stub_function(dbl._double_id, function_name, func)
          )
      end

    {:reply, dbl, state}
  end

  @doc false
  def handle_call({:clear, dbl, function_name}, _from, state) do
    FuncList.clear(state.func_list, function_name)
    {:reply, dbl, state}
  end

  defp stub_module(mod, state) do
    func_names_and_arities =
      state.func_list
      |> FuncList.list()
      |> MapSet.new(fn {func_name, func} -> {func_name, arity(func)} end)
      |> MapSet.to_list()

    stubbed_module = Registry.source_for("#{mod}")

    opts =
      Registry.opts_for("#{mod}")
      |> Map.put(:for, stubbed_module)

    func_defs = generate_function_defs(mod, stubbed_module, func_names_and_arities)

    quoted_use =
      quote do
        use Double.Stub, unquote(opts)
      end

    contents = [quoted_use, maybe_quoted_kernel_import(func_names_and_arities)] ++ func_defs

    %{ignore_module_conflict: ignore_module_conflict} = Code.compiler_options()
    Code.compiler_options(ignore_module_conflict: true)
    Module.create(mod, contents, Macro.Env.location(__ENV__))
    Code.compiler_options(ignore_module_conflict: ignore_module_conflict)
  end

  defp stub_function(double_id, function_name, func) do
    {signature, message} = function_parts(function_name, func, {false, nil})

    func_str = """
    fn(#{signature}) ->
      #{function_body(double_id, message, function_name, signature)}
    end
    """

    {result, _} = Code.eval_string(func_str)
    result
  end

  defp function_body(double_id, message, function_name, signature) do
    """
    test_pid = Double.Registry.whereis_test(\"#{double_id}\")
    Kernel.send(test_pid, #{message})
    pid = Double.Registry.whereis_double(\"#{double_id}\")
    func_list = Double.func_list(pid)
    Double.FuncList.apply(func_list, :#{function_name}, [#{signature}])
    """
  end

  defp function_parts(function_name, func, {send_stubbed_module, stubbed_module}) do
    signature =
      case arity(func) do
        0 ->
          ""

        x ->
          0..(x - 1)
          |> Enum.map(fn i -> <<97 + i::utf8>> end)
          |> Enum.join(", ")
      end

    message =
      case {send_stubbed_module, signature} do
        {true, _} -> "{#{atom_to_code_string(stubbed_module)}, :#{function_name}, [#{signature}]}"
        {false, ""} -> ":#{function_name}"
        _ -> "{:#{function_name}, #{signature}}"
      end

    {signature, message}
  end

  defp maybe_quoted_kernel_import(func_names_and_arities) do
    excepts = func_names_and_arities -- Kernel.__info__(:functions)

    if length(excepts) > 0 do
      quote do
        import Kernel, except: unquote(Macro.escape(excepts))
      end
    end
  end

  defp arity(func) do
    :erlang.fun_info(func)[:arity]
  end

  defp struct_key_error(dbl, key) do
    msg =
      "The struct #{dbl.__struct__} does not contain key: #{key}. Use a Map if you want to add dynamic function names."

    raise ArgumentError, message: msg
  end

  defp create_function_from_opts(opts) do
    args =
      case opts[:with] do
        {:any, with_arity} ->
          0..(with_arity - 1)
          |> Enum.map(fn i -> <<97 + i::utf8>> |> String.to_atom() end)
          |> Enum.map(fn arg_atom -> {arg_atom, [], Elixir} end)

        nil ->
          []

        with_args ->
          with_args
      end

    args
    |> quoted_fn(opts)
    |> Code.eval_quoted()
  end

  defp quoted_fn(args, opts) do
    {:fn, [], [{:->, [], [args, quoted_fn_body(opts, opts[:raises])]}]}
  end

  defp quoted_fn_body(_opts, {error_module, message}) do
    {
      :raise,
      [context: Elixir, import: Kernel],
      [{:__aliases__, [alias: false], [error_module]}, message]
    }
  end

  defp quoted_fn_body(_opts, message) when is_binary(message) do
    {
      :raise,
      [context: Elixir, import: Kernel],
      [message]
    }
  end

  defp quoted_fn_body(opts, nil) do
    opts[:returns]
  end

  defp atom_to_code_string(atom) do
    atom_str = Atom.to_string(atom)

    case String.downcase(atom_str) do
      ^atom_str -> ":#{atom_str}"
      _ -> atom_str
    end
  end
end
