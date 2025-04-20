defmodule Syslog.ServerTest do
  use ExUnit.Case
  alias Kvasir.Syslog.Server

  describe "UDP server" do
    setup do
      {:ok, server} = Kvasir.Application.start_server(port: 0, protocol: :udp)
      {:ok, consumer} = Kvasir.Consumer.start_link(server)
      {:ok, port} = Server.get_port(server)

      on_exit(fn ->
        :ok = Server.stop(server)
      end)

      %{server: server, consumer: consumer, port: port}
    end

    test "producing an event via UDP", %{port: port} do
      syslog_msg =
        "<165>1 2003-08-24T12:14:15.000003Z 192.0.2.1 myproc 8710 - - %% It's time to make the do-nuts."

      {:ok, socket} = :gen_udp.open(0)
      :gen_udp.send(socket, {127, 0, 0, 1}, port, syslog_msg)
      :gen_udp.close(socket)

      assert_receive [{^syslog_msg, "127.0.0.1"}]
    end
  end

  describe "TCP server" do
    setup do
      {:ok, server} = Kvasir.Application.start_server(port: 0, protocol: :tcp)
      {:ok, consumer} = Kvasir.Consumer.start_link(server)
      {:ok, port} = Server.get_port(server)

      on_exit(fn ->
        :ok = Server.stop(server)
      end)

      %{server: server, consumer: consumer, port: port}
    end

    test "producing an event via TCP", %{port: port} do
      syslog_msg =
        "<165>1 2003-08-24T12:14:15.000003Z 192.0.2.1 myproc 8710 - - %% It's time to make the do-nuts."

      {:ok, socket} = :gen_tcp.connect({127, 0, 0, 1}, port, [:binary, active: false])
      :ok = :gen_tcp.send(socket, syslog_msg)

      # Wait for the message to be received before closing the socket
      assert_receive [{^syslog_msg, "127.0.0.1"}], 1000

      # Now close the socket
      :gen_tcp.close(socket)

    end

    test "multiple client connections", %{port: port, server: _server} do
      # Create multiple messages
      msg1 = "<165>1 2003-08-24T12:14:15.000003Z 192.0.2.1 client1 8710 - - %% Message from client 1"
      msg2 = "<165>1 2003-08-24T12:14:15.000003Z 192.0.2.1 client2 8710 - - %% Message from client 2"
      msg3 = "<165>1 2003-08-24T12:14:15.000003Z 192.0.2.1 client3 8710 - - %% Message from client 3"

      # Connect and send from multiple clients
      {:ok, socket1} = :gen_tcp.connect({127, 0, 0, 1}, port, [:binary, active: false])
      {:ok, socket2} = :gen_tcp.connect({127, 0, 0, 1}, port, [:binary, active: false])
      {:ok, socket3} = :gen_tcp.connect({127, 0, 0, 1}, port, [:binary, active: false])

      :ok = :gen_tcp.send(socket1, msg1)
      :ok = :gen_tcp.send(socket2, msg2)
      :ok = :gen_tcp.send(socket3, msg3)

      # Verify all messages are received (order may vary)
      assert_receive [{message1, ip_address1}], 1000
      assert_receive [{message2, ip_address2}], 1000
      assert_receive [{message3, ip_address3}], 1000

      # Close all connections after messages are received
      :gen_tcp.close(socket1)
      :gen_tcp.close(socket2)
      :gen_tcp.close(socket3)

      # For TCP connections, we expect the IP addresses to be "127.0.0.1" in our test environment
      assert ip_address1 == "127.0.0.1"
      assert ip_address2 == "127.0.0.1"
      assert ip_address3 == "127.0.0.1"

      # Check that all messages were received (regardless of order)
      assert message1 in [msg1, msg2, msg3]
      assert message2 in [msg1, msg2, msg3]
      assert message3 in [msg1, msg2, msg3]
      assert message1 != message2
      assert message2 != message3
      assert message1 != message3
    end

    test "large message handling", %{port: port} do
      # Create a moderately large message (1KB)
      large_payload = String.duplicate("X", 1024)
      large_msg = "<165>1 2003-08-24T12:14:15.000003Z 192.0.2.1 myproc 8710 - - %% #{large_payload}"

      {:ok, socket} = :gen_tcp.connect({127, 0, 0, 1}, port, [:binary, active: false])
      :ok = :gen_tcp.send(socket, large_msg)

      # Since TCP might split the message, we'll check if we receive any message containing our payload
      assert_receive [{received_msg, ip_address}], 2000

      # Close the socket after the message is received
      :gen_tcp.close(socket)
      # For TCP connections, we expect the IP address to be "127.0.0.1" in our test environment
      assert ip_address == "127.0.0.1"
      assert String.contains?(received_msg, large_payload)
    end

    test "connection closure handling", %{port: port, server: server} do
      # Get initial state to check client count
      %GenStage{state: initial_state} = :sys.get_state(server)
      {_protocol, _socket, initial_clients} = initial_state
      initial_client_count = map_size(initial_clients)

      # Connect a client
      {:ok, socket} = :gen_tcp.connect({127, 0, 0, 1}, port, [:binary, active: false])

      # Give the server time to register the connection
      Process.sleep(100)

      # Check that a client was added
      %GenStage{state: state_after_connect} = :sys.get_state(server)
      {_protocol, _socket, clients_after_connect} = state_after_connect
      assert map_size(clients_after_connect) > initial_client_count

      # Close the connection
      :gen_tcp.close(socket)

      # Give the server time to process the disconnection
      Process.sleep(100)

      # Check that the client was removed
      %GenStage{state: state_after_close} = :sys.get_state(server)
      {_protocol, _socket, clients_after_close} = state_after_close
      assert map_size(clients_after_close) == initial_client_count
    end

  end

  test "default protocol is UDP" do
    {:ok, server} = Kvasir.Application.start_server(port: 0)

    # Get the server state
    %GenStage{state: state} = :sys.get_state(server)

    # Check that the protocol is UDP (first element of the state tuple)
    assert elem(state, 0) == :udp

    :ok = Server.stop(server)
  end
end
