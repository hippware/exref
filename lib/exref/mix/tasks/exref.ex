defmodule Mix.Tasks.Exref do
  use Mix.Task

  @moduledoc ""

  @shortdoc "Checks all function calls using xref"

  @default_checks [
    :locals_not_used, :exports_not_used,
    :deprecated_function_calls, :deprecated_functions
  ]

  def run(_args) do
    # make sure mix will let us run compile
    ensure_compile
    Mix.Task.run "compile"

    project = Mix.Project.config
    ebin_dir = Mix.Project.compile_path(project)

    :xref.start(:xref)
    :xref.set_default(:xref, [{:verbose, false}])
    :xref.add_directory(:xref, String.to_char_list(ebin_dir))

    r = xref_checks(@default_checks, [])
    display_results r

    if r != [], do: Mix.raise("xref found issues")
  end

  # ===================================================================
  # Internal functions
  # ===================================================================

  defp ensure_compile do
    # we have to reenable compile and all of its
    # child tasks (compile.erlang, compile.elixir, etc)
    Mix.Task.reenable("compile")
    Enum.each(compilers, &Mix.Task.reenable/1)
  end

  defp compilers do
    Mix.Task.all_modules
    |> Enum.map(&Mix.Task.task_name/1)
    |> Enum.filter(fn(t) -> match?("compile." <> _, t) end)
  end

  defp xref_checks(xref_checks, xref_ignores) do
    run_xref_checks(xref_checks, xref_ignores, [])
  end

  defp run_xref_checks([], _xref_ignores, acc) do
    acc
  end
  defp run_xref_checks([xref_check | t], xref_ignores, acc) do
    {:ok, results} = :xref.analyze(:xref, xref_check)
    case filter_xref_results(xref_check, xref_ignores, results) do
      [] ->
        run_xref_checks(t, xref_ignores, acc)
      filter_result ->
        run_xref_checks(t, xref_ignores, [{xref_check, filter_result} | acc])
    end
  end

  # Ignore behaviour functions, and explicitly marked functions
  #
  # Functions can be ignored by using
  # -ignore_xref([{F, A}, {M, F, A}...]).
  defp get_xref_ignorelist(mod, xref_check) do
    # Get ignore_xref attribute and combine them in one list
    attributes =
      try do
        mod.module_info(:attributes)
      rescue
        _ -> []
      end

    ignore_xref = keyall(:ignore_xref, attributes)

    behaviour_callbacks = get_behaviour_callbacks(xref_check, attributes)

    # And create a flat {M, F, A} list
    [ignore_xref, behaviour_callbacks]
    |> List.flatten
    |> List.foldl([],
      fn ({f, a}, acc) -> [{mod, f, a} | acc]
         ({m, f, a}, acc) -> [{m, f, a} | acc]
      end)
  end

  defp keyall(key, list) do
    Enum.flat_map(list,
                  fn ({k, l}) when key == k -> l
                     (_) -> []
                  end)
  end

  defp get_behaviour_callbacks(:exports_not_used, attributes) do
    for b <- keyall(:behaviour, attributes), do: b.behaviour_info(:callbacks)
  end
  defp get_behaviour_callbacks(_xref_check, _attributes) do
    []
  end

  defp parse_xref_result({_, mfat}), do: mfat
  defp parse_xref_result(mfat), do: mfat

  defp filter_xref_results(xref_check, xref_ignores, xref_results) do
    search_modules =
      xref_results
      |> Enum.map(fn ({mt, _ft, _at}) -> mt
                     ({{ms, _fs, _as}, {_mt, _ft, _at}}) -> ms
                     (_) -> nil
                  end)
      |> Enum.uniq

    ignores =
      search_modules
      |> Enum.flat_map(&get_xref_ignorelist(&1, xref_check))
      |> Enum.concat(xref_ignores)

    Enum.filter(xref_results,
                fn (r) -> not Enum.member?(ignores, parse_xref_result(r)) end)
  end

  defp display_results(xref_results) do
    Enum.map(xref_results, &display_xref_results_for_type/1)
  end

  defp display_xref_results_for_type({type, xref_results}) do
    Enum.map(xref_results, &display_xref_result_fun(type, &1))
  end

  defp display_xref_result_fun(type, xref_result) do
    {source, s_mfa, t_mfa} =
      case xref_result do
        {mfa_source, mfa_target} ->
          {format_mfa_source(mfa_source),
           format_mfa(mfa_source),
           format_mfa(mfa_target)}
        mfa_target ->
          {format_mfa_source(mfa_target),
           format_mfa(mfa_target),
           :undefined}
      end

    str =
      case type do
        :undefined_function_calls ->
          "#{source}Warning: #{s_mfa} calls undefined function #{t_mfa}"
        :undefined_functions ->
          "#{source}Warning: #{s_mfa} is undefined function"
        :locals_not_used ->
          "#{source}Warning: #{s_mfa} is unused local function"
        :exports_not_used ->
          "#{source}Warning: #{s_mfa} is unused export"
        :deprecated_function_calls ->
          "#{source}Warning: #{s_mfa} calls deprecated function #{t_mfa}"
        :deprecated_functions ->
          "#{source}Warning: #{s_mfa} is deprecated function"
        other ->
          "#{source}Warning: #{s_mfa} - #{t_mfa} xref check: #{other}"
      end

    Mix.shell.info str
  end

  defp format_mfa({m, f, a}) do
    "#{m}:#{f}/#{a}"
  end

  defp format_mfa_source(mfa) do
    case find_mfa_source(mfa) do
      {:module_not_found, :function_not_found} -> ""
      {source, :function_not_found} -> "#{source}: "
      {source, line} -> "#{source}:#{line}: "
    end
  end

  #
  # Extract an element from a tuple, or undefined if N > tuple size
  #
  defp safe_element(n, tuple) do
    try do
      elem(n, tuple)
    rescue
      _ ->
        :undefined
    end
  end

  #
  # Given a MFA, find the file and LOC where it's defined. Note that
  # xref doesn't work if there is no abstract_code, so we can avoid
  # being too paranoid here.
  #
  defp find_mfa_source({m, f, a}) do
    case :code.get_object_code(m) do
      :error -> {:module_not_found, :function_not_found}
      {m, bin, _} -> find_function_source(m, f, a, bin)
    end
  end

  defp find_function_source(m, f, a, bin) do
    abstract_code = :beam_lib.chunks(bin, [:abstract_code])
    {:ok, {^m, [{:abstract_code, {:raw_abstract_v1, code}}]}} = abstract_code
    # Extract the original source filename from the abstract code
    {:attribute, 1, :file, {source, _}} = List.keyfind(code, :file, 2)
    string_souce = List.to_string(source)
    # Extract the line number for a given function def
    fun = Enum.filter(code,
                      fn(e) ->
                        safe_element(1, e) == :function and
                        safe_element(3, e) == f and
                        safe_element(4, e) == a
                      end)
    case fun do
      [{:function, line, ^f, _, _}] -> {string_souce, line}
      # do not crash if functions are exported, even though they
      # are not in the source.
      # parameterized modules add new/1 and instance/1 for example.
      [] -> {string_souce, :function_not_found}
    end
  end
end
