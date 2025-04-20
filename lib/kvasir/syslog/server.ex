defmodule Kvasir.Syslog.Server do
  @moduledoc """
  Creates a server for listening for syslog messages.
  The default port for listening for new incoming messages is 5544.
  The default protocol is UDP.
  See `start_link/1` for checking the options you can use.
  """
  use GenStage, restart: :transient

  @default_port 5544
  @default_protocol :udp

  @doc """
  Starts the syslog server. You can provide a keyword list of
  options:

  - `port` to indicate the port where the server will start listening.
  - `protocol` to specify the protocol to use (`:udp` or `:tcp`). Defaults to `:udp`.
  """
  def start_link(opts) do
    GenStage.start_link(__MODULE__, opts)
  end

  @doc """
  Get the port where the syslog server is listening.
  """
  @spec get_port(GenServer.server()) :: pos_integer()
  def get_port(pid) do
    GenStage.call(pid, :port)
  end

  @doc """
  Stops the server. It's useful if we need starting a server out of a supervisor,
  or we need the server will be restarted inside of the supervisor.
  """
  @spec stop(GenServer.server()) :: :ok
  defdelegate stop(pid), to: GenStage

  @impl GenStage
  @doc false
  def init(opts) do
    port = opts[:port] || @default_port
    protocol = opts[:protocol] || @default_protocol

    case protocol do
      :udp ->
        {:ok, socket} = :gen_udp.open(port, [:binary])
        {:producer, {protocol, socket}, dispatcher: GenStage.DemandDispatcher}
      :tcp ->
        # For TCP, we first create a listening socket that waits for client connections
        {:ok, socket} = :gen_tcp.listen(port, [:binary, active: true, reuseaddr: true])
        # Send ourselves an :accept message to start the connection acceptance loop
        # This is a common pattern in Erlang/Elixir for TCP servers
        send(self(), :accept)
        # The state includes a map to track connected clients
        {:producer, {protocol, socket, %{}}, dispatcher: GenStage.DemandDispatcher}
      _ ->
        {:stop, {:error, "Invalid protocol: #{protocol}. Must be :udp or :tcp"}}
    end
  end

  @impl GenStage
  @doc false
  def terminate(_reason, {protocol, socket}) when protocol == :udp do
    :gen_udp.close(socket)
    :ok
  end

  def terminate(_reason, {protocol, socket, _clients}) when protocol == :tcp do
    :gen_tcp.close(socket)
    :ok
  end

  # Handle UDP messages
  @impl GenStage
  @doc false
  def handle_info({:udp, socket, ip, _port, message}, {protocol, socket} = state) when protocol == :udp do
    # Convert IP tuple to string format
    ip_str = :inet.ntoa(ip) |> to_string()
    {:noreply, [{message, ip_str}], state}
  end

  # Accept new TCP connections
  # This function implements the TCP connection acceptance loop:
  # 1. It tries to accept a new client connection (non-blocking with timeout 0)
  # 2. If successful, it configures the client socket and stores it
  # 3. It then schedules another :accept message to continue the loop
  # 4. This creates a continuous cycle of checking for and accepting new connections
  def handle_info(:accept, {protocol, socket, clients} = state) when protocol == :tcp do
    case :gen_tcp.accept(socket, 0) do
      {:ok, client} ->
        # Configure the client socket to be in active mode
        # In active mode, incoming data is automatically sent as messages to this process
        :ok = :inet.setopts(client, [active: true])

        # Store client socket with a unique reference as key for later identification
        ref = make_ref()

        # Schedule another accept operation to handle the next connection
        # This creates a continuous loop of accepting connections without blocking
        send(self(), :accept)

        # Return updated state with the new client added to the clients map
        {:noreply, [], {protocol, socket, Map.put(clients, ref, client)}}

      {:error, :timeout} ->
        # No pending connections, schedule another accept operation
        # The timeout of 0 makes :gen_tcp.accept non-blocking, so we need to
        # explicitly continue the accept loop
        send(self(), :accept)
        {:noreply, [], state}

      {:error, reason} ->
        # Handle other errors by stopping the server
        {:stop, reason, state}
    end
  end

  # Handle TCP messages
  # When a TCP socket is in active mode, incoming data is automatically
  # sent to the controlling process (this GenStage) as {:tcp, socket, data} messages
  def handle_info({:tcp, client_socket, message}, {protocol, _socket, clients} = state) when protocol == :tcp do
    # Find the client reference by looking up the socket in our clients map
    client_ref = Enum.find_value(clients, fn {ref, sock} -> if sock == client_socket, do: ref, else: nil end)
    if client_ref do
      # If we found the client, get the IP address
      {:ok, {ip, _port}} = :inet.peername(client_socket)
      ip_str = :inet.ntoa(ip) |> to_string()
      {:noreply, [{message, ip_str}], state}
      # The return is handled in the case statement above
    else
      # If client not found (unexpected), ignore the message
      {:noreply, [], state}
    end
  end

  # Handle TCP closed connections
  # When a client disconnects, the TCP socket sends a {:tcp_closed, socket} message
  # This allows us to clean up the connection and remove it from our state
  def handle_info({:tcp_closed, client_socket}, {protocol, socket, clients} = state) when protocol == :tcp do
    # Find the client reference by looking up the socket in our clients map
    client_ref = Enum.find_value(clients, fn {ref, sock} -> if sock == client_socket, do: ref, else: nil end)
    if client_ref do
      # If we found the client, remove it from our state
      {:noreply, [], {protocol, socket, Map.delete(clients, client_ref)}}
    else
      # If client not found (unusual case), keep state unchanged
      {:noreply, [], state}
    end
  end

  @impl GenStage
  @doc false
  def handle_call(:port, _from, {protocol, socket}) when protocol == :udp do
    {:reply, :inet.port(socket), [], {protocol, socket}}
  end

  def handle_call(:port, _from, {protocol, socket, clients}) when protocol == :tcp do
    {:reply, :inet.port(socket), [], {protocol, socket, clients}}
  end

  @impl GenStage
  @doc false
  def handle_demand(_demand, state) do
    {:noreply, [], state}
  end
end
