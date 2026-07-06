defmodule Playwright do
  @moduledoc """
  Executes JavaScript scenarios in persistent Playwright browsers.

  Chromium and Firefox are launched once by `start/1`. Each call to `run!/3`
  receives a fresh browser context and page, so tests are isolated without
  paying the cost of launching a browser for every scenario.
  """

  require Logger

  @type browser :: :chromium | :firefox
  @type context :: map()
  @type result :: JSON.t()

  @spec start(keyword()) :: :ok
  @spec ensure_started() :: :ok
  @spec evaluate!(String.t(), context()) :: result()
  @spec run!(browser(), String.t(), context()) :: result()

  @server_path Path.expand("playwright_server.js", __DIR__)
  @default_port 4456
  @request_timeout 60_000
  @browsers [:chromium, :firefox]

  defmacro __using__(_opts) do
    quote do
      import Playwright, only: [playwright: 1]

      setup_all do
        Playwright.ensure_started()
        :ok
      end

      setup context do
        if script = context[:playwright_js],
          do: {:ok, js: Playwright.evaluate!(script)},
          else: :ok
      end
    end
  end

  defmacro playwright(do: block) do
    block
    |> block_expressions()
    |> annotate_playwright_tests(__CALLER__)
    |> then(&{:__block__, [], &1})
  end

  def start(opts \\ []) do
    port = Keyword.get(opts, :port, @default_port)
    node_path = find_npx_node_path!()
    browser_names = configured_browsers() |> Enum.map_join(",", &Atom.to_string/1)

    {:ok, _pid} =
      Task.start(fn ->
        MuonTrap.cmd("node", [@server_path, Integer.to_string(port), browser_names],
          stderr_to_stdout: true,
          env: [{"NODE_PATH", node_path}]
        )
      end)

    wait_for_server(port)
    :persistent_term.put({__MODULE__, :port}, port)
    Logger.info("[Playwright] #{browser_names} ready on port #{port}")
    :ok
  end

  def ensure_started do
    :global.trans({__MODULE__, :server}, fn ->
      if server_available?(configured_port()) do
        :ok
      else
        start()
      end
    end)
  end

  def evaluate!(script, context \\ %{}) do
    case configured_browsers() do
      [browser] ->
        run!(browser, script, context)

      browsers ->
        results =
          browsers
          |> Task.async_stream(
            fn browser -> {browser, run!(browser, script, context)} end,
            max_concurrency: length(browsers),
            ordered: false,
            timeout: @request_timeout + 5_000
          )
          |> Map.new(fn
            {:ok, result} -> result
            {:exit, reason} -> exit(reason)
          end)

        consensus_result!(results)
    end
  end

  def run!(browser, script, context \\ %{}) do
    port = configured_port()

    {:ok, socket} =
      :gen_tcp.connect(~c"127.0.0.1", port, [:binary, active: false, packet: :raw], 5_000)

    try do
      execute_script(socket, browser, script, context)
    after
      :gen_tcp.close(socket)
    end
  end

  defp configured_browsers do
    case System.get_env("PLAYWRIGHT_BROWSER") do
      nil ->
        @browsers

      "" ->
        @browsers

      "chromium" ->
        [:chromium]

      "firefox" ->
        [:firefox]

      browser ->
        raise ArgumentError,
              "invalid PLAYWRIGHT_BROWSER=#{inspect(browser)}; expected chromium or firefox"
    end
  end

  defp consensus_result!(results) do
    case results |> Map.values() |> Enum.uniq() do
      [result] ->
        result

      _different_results ->
        raise """
        Playwright browser oracles disagree:

        #{inspect(results, pretty: true, limit: :infinity)}
        """
    end
  end

  defp execute_script(socket, browser, script, context) do
    payload = %{
      browser: Atom.to_string(browser),
      script: script,
      context: context
    }

    json = JSON.encode!(payload)
    length_prefix = String.pad_leading(Integer.to_string(byte_size(json)), 8, "0")
    :ok = :gen_tcp.send(socket, length_prefix <> json)

    case recv_response(socket) do
      {:ok, %{"success" => true} = response} ->
        Map.get(response, "data")

      {:ok, %{"success" => false} = response} ->
        error = Map.get(response, "error", "unknown error")
        stack = Map.get(response, "stack")
        raise "Playwright #{browser} scenario failed:\n#{error}\n#{stack}"

      {:error, reason} ->
        raise "Playwright communication error: #{inspect(reason)}"
    end
  end

  defp recv_response(socket) do
    with {:ok, length_bytes} <- :gen_tcp.recv(socket, 8, @request_timeout),
         {length, ""} <- Integer.parse(length_bytes),
         {:ok, json} <- :gen_tcp.recv(socket, length, @request_timeout) do
      {:ok, JSON.decode!(json)}
    else
      :error -> {:error, :invalid_length}
      {:error, reason} -> {:error, reason}
      {_length, remainder} -> {:error, {:invalid_length, remainder}}
    end
  end

  defp wait_for_server(port), do: wait_for_server(port, 100)

  defp wait_for_server(_port, 0), do: raise("Playwright server did not start")

  defp wait_for_server(port, attempts) do
    if server_available?(port) do
      :ok
    else
      Process.sleep(100)
      wait_for_server(port, attempts - 1)
    end
  end

  defp server_available?(port) do
    case :gen_tcp.connect(~c"127.0.0.1", port, [], 100) do
      {:ok, socket} ->
        :gen_tcp.close(socket)
        true

      {:error, _reason} ->
        false
    end
  end

  defp configured_port do
    :persistent_term.get({__MODULE__, :port}, @default_port)
  end

  defp find_npx_node_path! do
    npm_cache =
      if cache = System.get_env("npm_config_cache"),
        do: cache,
        else: Path.expand("~/.npm")

    pattern = Path.join([npm_cache, "_npx", "*", "node_modules", "playwright", "package.json"])

    case Path.wildcard(pattern) do
      [] ->
        raise """
        Playwright is not installed in the npx cache.

        Install Playwright and its browser binaries with:

            npx --yes playwright@latest install chromium firefox
        """

      package_files ->
        package_files
        |> Enum.max_by(&File.stat!(&1).mtime)
        |> Path.dirname()
        |> Path.dirname()
    end
  end

  defp block_expressions({:__block__, _meta, expressions}), do: expressions
  defp block_expressions(expression), do: [expression]

  defp annotate_playwright_tests(expressions, caller) do
    {annotated, _link, pending_js} =
      Enum.reduce(expressions, {[], nil, nil}, fn expression, {annotated, link, pending_js} ->
        case expression do
          {:@, _, [{:js, _, [script]}]} ->
            {annotated, link, script}

          {:@, _, [{:link, _, [next_link]}]} ->
            {annotated, next_link, pending_js}

          {:test, _, _} = test when not is_nil(pending_js) ->
            tags = playwright_tags(pending_js, link)
            {annotated ++ tags ++ [test], link, nil}

          {:test, meta, _} ->
            compile_error!(caller, meta, "playwright test is missing @js")

          _other when not is_nil(pending_js) ->
            compile_error!(caller, [], "@js must appear immediately before a test")

          other ->
            {annotated ++ [other], link, pending_js}
        end
      end)

    if pending_js do
      compile_error!(caller, [], "unused @js at the end of a playwright block")
    end

    annotated
  end

  defp playwright_tags(pending_js, link) do
    link_tags =
      if link do
        [quote(do: @tag(playwright_link: unquote(link)))]
      else
        []
      end

    [
      quote(do: @tag(playwright_js: unquote(pending_js))),
      quote(do: @tag(:playwright))
    ] ++ link_tags
  end

  defp compile_error!(caller, meta, description) do
    raise CompileError,
      file: caller.file,
      line: meta[:line] || caller.line,
      description: description
  end
end
