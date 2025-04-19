# Kvasir

[![Build Status](https://github.com/altenwald/kvasir/actions/workflows/elixir.yml/badge.svg)](https://github.com/altenwald/kvasir/actions/workflows/elixir.yml)
[![License: LGPL 2.1](https://img.shields.io/github/license/altenwald/kvasir.svg)](https://raw.githubusercontent.com/altenwald/kvasir/main/COPYING)
[![Hex](https://img.shields.io/hexpm/v/kvasir_syslog.svg)](https://hex.pm/packages/kvasir_syslog)

Elixir Syslog server, client, and backend for Logger.

Kvasir's goal is to keep everything we could need regarding Syslog. If we need a client,
a server, or provide a backend for Logger.

## Features

- **Syslog Server**: Listen for syslog messages over UDP or TCP
- **Syslog Client**: Send syslog messages to remote servers
- **Logger Backend**: Use syslog for your Elixir application logs

## Installation

You can install Kvasir via Hex:

```elixir
{:kvasir_syslog, "~> 1.0"}
```

Or if you want to install the most recent (that could be still not uploaded to Hex):

```elixir
{:kvasir, github: "altenwald/kvasir"}
```

## Usage

### Syslog Server

You can start a syslog server with the following options:

```elixir
# Start a UDP server (default) on port 5544 (default)
{:ok, server} = Kvasir.Application.start_server([])

# Start a UDP server on a specific port
{:ok, server} = Kvasir.Application.start_server(port: 6000)


# Start a TCP server on a specific port
{:ok, server} = Kvasir.Application.start_server(port: 6000, protocol: :tcp)
```

#### Server Options

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `port` | integer | `5544` | The port number to listen on |
| `protocol` | atom | `:udp` | The protocol to use (`:udp` or `:tcp`) |

### Syslog Client

Documentation for the client usage will be added soon.

### Logger Backend

Documentation for the logger backend usage will be added soon.

## Kvasir Syslog Server Guide

### Architecture

Kvasir Syslog provides a complete syslog server implementation with the following components:

1. **Kvasir.Syslog.Server**: Listens on a UDP/TCP port and receives raw syslog messages
2. **Kvasir.Syslog.Decoder**: Decodes raw syslog messages into `%Kvasir.Syslog{}` structs
3. **Your Consumer**: A GenStage consumer that subscribes to the Decoder

```
flowchart LR
    A([UDP/TCP Port]) --> B["Kvasir.Syslog.Server"]
    B --> C["Kvasir.Syslog.Decoder"]
    C --> D["Your Handler (GenStage Consumer)"]
```

### Implementation Details

#### Starting the Components

Kvasir uses a DynamicSupervisor to manage its components. The proper way to start the components is:

1. Start the Kvasir.Syslog.Server using Kvasir.Application.start_server/1
2. Start the Kvasir.Syslog.Decoder using Kvasir.Application.start_decoder/1, passing the server as the producer
3. Start your handler as a GenStage consumer that subscribes to the decoder

```elixir
# In your application.ex
def start(_type, _args) do
  # Start the Kvasir Syslog server
  {:ok, server} = Kvasir.Application.start_server(port: 514, protocol: :tcp)

  # Start a decoder that subscribes to the server
  {:ok, decoder} = Kvasir.Application.start_decoder(producer: server)

  # Start your handler that subscribes to the decoder
  {:ok, _handler} = YourApp.Handler.start_link(decoder: decoder)

  opts = [strategy: :one_for_one, name: YourApp.Supervisor]
  Supervisor.start_link(children, opts)
end
```

#### Creating a Handler

Your handler should be a GenStage consumer that subscribes to the decoder:

```elixir
defmodule YourApp.Handler do
  use GenStage
  require Logger

  def start_link(opts) do
    GenStage.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(opts) do
    # Get the decoder from the options
    decoder = Keyword.get(opts, :decoder)

    if decoder do
      Logger.info("Subscribing to decoder: #{inspect(decoder)}")
      # Subscribe to the decoder
      {:consumer, :ok, subscribe_to: [decoder]}
    else
      Logger.error("No decoder provided in options")
      {:consumer, :ok}
    end
  end

  @impl true
  def handle_events(events, _from, state) do
    for %Kvasir.Syslog{facility: f, severity: s, hostname: h, message: m} = syslog_message <- events do
      # Process each syslog message
      Logger.info("[#{f}/#{s}] #{h}: #{m}")

      # Your custom processing logic here
    end

    {:noreply, [], state}
  end
end
```

