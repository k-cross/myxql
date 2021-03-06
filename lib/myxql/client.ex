defmodule MyXQL.Client do
  @moduledoc false

  require Logger
  import MyXQL.Protocol.{Flags, Messages, Records, Types}
  alias MyXQL.Protocol.Auth

  defmodule Config do
    @moduledoc false

    defstruct [
      :address,
      :port,
      :username,
      :password,
      :database,
      :ssl?,
      :ssl_opts,
      :connect_timeout,
      :handshake_timeout,
      :socket_options
    ]

    def new(opts) do
      {address, port} = address_and_port(opts)

      %__MODULE__{
        address: address,
        port: port,
        username:
          Keyword.get(opts, :username, System.get_env("USER")) || raise(":username is missing"),
        password: Keyword.get(opts, :password),
        database: Keyword.get(opts, :database),
        ssl?: Keyword.get(opts, :ssl, false),
        ssl_opts: Keyword.get(opts, :ssl_opts, []),
        connect_timeout: Keyword.get(opts, :connect_timeout, 15_000),
        handshake_timeout: Keyword.get(opts, :handshake_timeout, 15_000),
        socket_options:
          Keyword.merge([mode: :binary, packet: :raw, active: false], opts[:socket_options] || [])
      }
    end

    defp address_and_port(opts) do
      default_protocol =
        if (Keyword.has_key?(opts, :hostname) or Keyword.has_key?(opts, :port)) and
             not Keyword.has_key?(opts, :socket) do
          :tcp
        else
          :socket
        end

      protocol = Keyword.get(opts, :protocol, default_protocol)

      case protocol do
        :socket ->
          default_socket = System.get_env("MYSQL_UNIX_PORT") || "/tmp/mysql.sock"
          socket = Keyword.get(opts, :socket, default_socket)
          {{:local, socket}, 0}

        :tcp ->
          hostname = Keyword.get(opts, :hostname, "localhost")
          default_port = String.to_integer(System.get_env("MYSQL_TCP_PORT") || "3306")
          port = Keyword.get(opts, :port, default_port)
          {String.to_charlist(hostname), port}
      end
    end
  end

  def connect(opts) when is_list(opts) do
    connect(Config.new(opts))
  end

  def connect(%Config{} = config) do
    with {:ok, sock} <- do_connect(config) do
      state = %{sock: {:gen_tcp, sock}, connection_id: nil}
      handshake(config, state)
    end
  end

  def com_ping(state) do
    with :ok <- send_com(:com_ping, state) do
      recv_packet(&decode_generic_response/1, state.ping_timeout, state)
    end
  end

  def com_query(statement, state) do
    with :ok <- send_com({:com_query, statement}, state) do
      recv_packets(&decode_com_query_response/3, :initial, state)
    end
  end

  def com_stmt_prepare(statement, state) do
    with :ok <- send_com({:com_stmt_prepare, statement}, state) do
      recv_packets(&decode_com_stmt_prepare_response/3, :initial, state)
    end
  end

  def com_stmt_execute(statement_id, params, cursor_type, state) do
    with :ok <- send_com({:com_stmt_execute, statement_id, params, cursor_type}, state) do
      recv_packets(&decode_com_stmt_execute_response/3, :initial, state)
    end
  end

  def com_stmt_fetch(statement_id, column_defs, max_rows, state) do
    with :ok <- send_com({:com_stmt_fetch, statement_id, max_rows}, state) do
      recv_packets(&decode_com_stmt_fetch_response/3, {:initial, column_defs}, state)
    end
  end

  def com_stmt_reset(statement_id, state) do
    with :ok <- send_com({:com_stmt_reset, statement_id}, state) do
      recv_packet(&decode_generic_response/1, state)
    end
  end

  def com_stmt_close(statement_id, state) do
    # No response is sent back to the client.
    :ok = send_com({:com_stmt_close, statement_id}, state)
  end

  def disconnect(state) do
    sock_close(state)
  end

  def send_com(com, state) do
    payload = encode_com(com)
    send_packet(payload, 0, state)
  end

  def send_packet(payload, sequence_id, state) do
    data = encode_packet(payload, sequence_id)
    send_data(state, data)
  end

  def send_data(%{sock: {sock_mod, sock}}, data) do
    sock_mod.send(sock, data)
  end

  def recv_packet(decoder, timeout \\ :infinity, state) do
    new_decoder = fn payload, "", nil -> {:halt, decoder.(payload)} end
    recv_packets(new_decoder, nil, timeout, state)
  end

  def recv_packets(decoder, decoder_state, timeout \\ :infinity, state) do
    case recv_data(state, timeout) do
      {:ok, data} ->
        recv_packets(data, decoder, decoder_state, timeout, state)

      {:error, _} = error ->
        error
    end
  end

  def recv_data(%{sock: {sock_mod, sock}}, timeout) do
    sock_mod.recv(sock, 0, timeout)
  end

  ## Internals

  defp recv_packets(
         <<size::uint3, _seq::uint1, payload::string(size), rest::binary>>,
         decoder,
         decoder_state,
         timeout,
         state
       ) do
    case decoder.(payload, rest, decoder_state) do
      {:cont, decoder_state} ->
        recv_packets(rest, decoder, decoder_state, timeout, state)

      {:halt, result} ->
        {:ok, result}

      {:error, _} = error ->
        error
    end
  end

  # If we didn't match on a full packet, receive more data and try again
  defp recv_packets(rest, decoder, decoder_state, timeout, state) do
    case recv_data(state, timeout) do
      {:ok, data} ->
        recv_packets(<<rest::binary, data::binary>>, decoder, decoder_state, timeout, state)

      {:error, _} = error ->
        error
    end
  end

  defp sock_close(%{sock: {sock_mod, sock}}) do
    sock_mod.close(sock)
  end

  ## Handshake

  defp do_connect(config) do
    %{
      address: address,
      port: port,
      socket_options: socket_options,
      connect_timeout: connect_timeout
    } = config

    buffer? = Keyword.has_key?(socket_options, :buffer)

    case :gen_tcp.connect(address, port, socket_options, connect_timeout) do
      {:ok, sock} when buffer? ->
        {:ok, sock}

      {:ok, sock} ->
        {:ok, [sndbuf: sndbuf, recbuf: recbuf, buffer: buffer]} =
          :inet.getopts(sock, [:sndbuf, :recbuf, :buffer])

        buffer = buffer |> max(sndbuf) |> max(recbuf)
        :ok = :inet.setopts(sock, buffer: buffer)
        {:ok, sock}

      other ->
        other
    end
  end

  defp handshake(config, %{sock: {:gen_tcp, sock}} = state) do
    timer = start_handshake_timer(config.handshake_timeout, sock)

    case do_handshake(config, state) do
      {:ok, state} ->
        cancel_handshake_timer(timer)
        {:ok, state}

      {:error, reason} ->
        cancel_handshake_timer(timer)
        {:error, reason}
    end
  end

  defp do_handshake(config, state) do
    with {:ok, initial_handshake(conn_id: conn_id) = initial_handshake} <- recv_handshake(state),
         state = %{state | connection_id: conn_id},
         sequence_id = 1,
         :ok <- ensure_capabilities(initial_handshake),
         {:ok, sequence_id, state} <- maybe_upgrade_to_ssl(config, sequence_id, state) do
      send_handshake_response(config, initial_handshake, sequence_id, state)
    end
  end

  defp recv_handshake(state) do
    recv_packet(&decode_initial_handshake/1, state)
  end

  defp ensure_capabilities(initial_handshake(capability_flags: capability_flags)) do
    if has_capability_flag?(capability_flags, :client_deprecate_eof) do
      :ok
    else
      {:error, :server_not_supported}
    end
  end

  defp send_handshake_response(
         config,
         initial_handshake,
         sequence_id,
         state
       ) do
    initial_handshake(
      auth_plugin_name: auth_plugin_name,
      auth_plugin_data: auth_plugin_data
    ) = initial_handshake

    auth_response = auth_response(auth_plugin_name, auth_plugin_data, config.password)

    payload =
      encode_handshake_response_41(
        config.username,
        auth_plugin_name,
        auth_response,
        config.database,
        config.ssl?
      )

    with :ok <- send_packet(payload, sequence_id, state) do
      case recv_packet(&decode_handshake_response/1, state) do
        {:ok, ok_packet()} ->
          {:ok, state}

        {:ok, err_packet() = err_packet} ->
          {:error, err_packet}

        {:ok, auth_switch_request(plugin_name: plugin_name, plugin_data: plugin_data)} ->
          with {:ok, auth_response} <-
                 auth_switch_response(plugin_name, config.password, plugin_data, config.ssl?),
               :ok <- send_packet(auth_response, sequence_id + 2, state) do
            case recv_packet(&decode_handshake_response/1, state) do
              {:ok, ok_packet(num_warnings: 0)} ->
                {:ok, state}

              {:ok, err_packet() = err_packet} ->
                {:error, err_packet}

              {:error, _reason} = error ->
                error
            end
          end

        {:ok, :full_auth} ->
          if config.ssl? do
            auth_response = config.password <> <<0x00>>

            with :ok <- send_packet(auth_response, sequence_id + 2, state) do
              case recv_packet(&decode_handshake_response/1, state) do
                {:ok, ok_packet(num_warnings: 0)} ->
                  {:ok, state}

                {:ok, err_packet() = err_packet} ->
                  {:error, err_packet}

                {:error, _reason} = error ->
                  error
              end
            end
          else
            auth_plugin_secure_connection_error(auth_plugin_name)
          end

        {:error, _reason} = error ->
          error
      end
    end
  end

  defp auth_response(_plugin_name, _plugin_data, nil),
    do: nil

  defp auth_response("mysql_native_password", plugin_data, password),
    do: Auth.mysql_native_password(password, plugin_data)

  defp auth_response(plugin_name, plugin_data, password)
       when plugin_name in ["sha256_password", "caching_sha2_password"],
       do: Auth.sha256_password(password, plugin_data)

  defp auth_switch_response(_plugin_name, nil, _plugin_data, _ssl?),
    do: {:ok, <<>>}

  defp auth_switch_response("mysql_native_password", password, plugin_data, _ssl?),
    do: {:ok, Auth.mysql_native_password(password, plugin_data)}

  defp auth_switch_response(plugin_name, password, _plugin_data, ssl?)
       when plugin_name in ["sha256_password", "caching_sha2_password"] do
    if ssl? do
      {:ok, password <> <<0x00>>}
    else
      auth_plugin_secure_connection_error(plugin_name)
    end
  end

  # https://dev.mysql.com/doc/refman/8.0/en/client-error-reference.html#error_cr_auth_plugin_err
  defp auth_plugin_secure_connection_error(plugin_name) do
    {:error, {:auth_plugin_error, {plugin_name, "Authentication requires secure connection"}}}
  end

  defp maybe_upgrade_to_ssl(%{ssl?: true} = config, sequence_id, state) do
    {_, sock} = state.sock
    payload = encode_ssl_request(config.database)

    with :ok <- send_packet(payload, sequence_id, state),
         {:ok, ssl_sock} <- :ssl.connect(sock, config.ssl_opts, config.connect_timeout) do
      {:ok, sequence_id + 1, %{state | sock: {:ssl, ssl_sock}}}
    end
  end

  defp maybe_upgrade_to_ssl(%{ssl?: false}, sequence_id, state) do
    {:ok, sequence_id, state}
  end

  defp start_handshake_timer(:infinity, _), do: :infinity

  defp start_handshake_timer(timeout, sock) do
    args = [timeout, self(), sock]
    {:ok, tref} = :timer.apply_after(timeout, __MODULE__, :handshake_shutdown, args)
    {:timer, tref}
  end

  @doc false
  def handshake_shutdown(timeout, pid, sock) do
    if Process.alive?(pid) do
      Logger.error(fn ->
        [
          inspect(__MODULE__),
          " (",
          inspect(pid),
          ") timed out because it was handshaking for longer than ",
          to_string(timeout) | "ms"
        ]
      end)

      :gen_tcp.shutdown(sock, :read_write)
    end
  end

  def cancel_handshake_timer(:infinity), do: :ok

  def cancel_handshake_timer({:timer, tref}) do
    {:ok, _} = :timer.cancel(tref)
    :ok
  end
end
