defmodule Kvasir.Syslog.Parser do
  @moduledoc """
  Parse the syslog message and encode it as a syslog structure.
  """
  import Bitwise
  require Logger
  alias Kvasir.Syslog

  @default_timezone "Etc/UTC"

  defguardp rfc3164?(text) when text in ["PRI invalid", "VERSION invalid"]

  @doc """
  Parse the text message as a Syslog struct or returns a parser error.
  The function tries to parse first for RFC5424 and if that's failing
  then it's trying to parse RFC3164.
  """
  def parse(message) do
    case parse_rfc5424(message) do
      %Syslog{} = syslog ->
        syslog

      {:error, {text, _}} when rfc3164?(text) ->
        parse_rfc3164(message)

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Parse the text message based on the RFC5424 and if that's failing it's
  returning an error.
  """
  def parse_rfc5424(message) do
    {message, Syslog.new()}
    |> parse_prival()
    |> parse_version()
    |> parse_timestamp()
    |> parse_string(&Syslog.set_hostname/2, "HOSTNAME", 255)
    |> parse_string(&Syslog.set_app_name/2, "APP-NAME", 48)
    |> parse_string(&Syslog.set_process_id/2, "PROCID", 128)
    |> parse_string(&Syslog.set_message_id/2, "MSGID", 32)
    |> parse_structured_data()
    |> parse_message()
    |> then(fn
      {"", syslog} -> syslog
      {{:error, reason}, _syslog} ->
        # Fall back to RFC3164 parsing for invalid RFC5424 messages
        {:error, {reason, message}}
    end)
  end

  @doc """
  Parse the text message based on the RFC3164 and if that's failing it's
  returning an error.
  """
  def parse_rfc3164(message) do
    {message, Syslog.new(:rfc3164)}
    |> parse_prival()
    |> parse_old_timestamp()
    |> parse_string(&Syslog.set_hostname/2, "HOSTNAME", 255)
    |> maybe_parse_ip_address()
    |> parse_old_process()
    |> parse_old_structured_data()
    |> parse_old_message(message)
    |> then(fn {"", syslog} -> syslog end)
  end

  defp parse_prival({"<" <> rest_message, syslog}) do
    case Integer.parse(rest_message) do
      {prival, ">" <> rest_message} ->
        # Handle additional number after PRI (e.g., "<189>8103: Apr 20...")
        rest_message = case Regex.run(~r/^([0-9]+): /, rest_message) do
          [match, _number] -> String.replace(rest_message, match, "", global: false)
          nil -> rest_message
        end

        syslog
        |> Syslog.set_severity(prival &&& 7)
        |> Syslog.set_facility(prival >>> 3)
        |> then(&{rest_message, &1})

      _ ->
        {{:error, "PRI number not found"}, syslog}
    end
  end

  defp parse_prival({_message, syslog}) do
    {{:error, "PRI invalid"}, syslog}
  end

  defp parse_version({{:error, _} = error, syslog}), do: {error, syslog}

  defp parse_version({message, syslog}) do
    case Integer.parse(message) do
      #  There's only one version registered by IANA according to
      #  RFC5424, section 9.1.
      {1 = version, " " <> rest_message} ->
        syslog
        |> Syslog.set_version(version)
        |> then(&{rest_message, &1})

      _ ->
        {{:error, "VERSION invalid"}, syslog}
    end
  end

  defp parse_old_timestamp({{:error, _} = error, syslog}), do: {error, syslog}

  defp parse_old_timestamp({"- " <> rest_message, syslog}), do: {rest_message, syslog}

  defp parse_old_timestamp({message, syslog}) do
    [
      ~r/^([0-9]{4}) ([A-Z][a-z]{2}) {1,2}([0-9]{1,2}) ([0-9]{2}:[0-9]{2}:[0-9]{2})(?: ([A-Z]{2,4}|TZ-[0-9]{1,2}))? (.*)$/,
      # Cisco CUCM format: "Oct 14 2015 05:50:19 AM.484 UTC :  %UC_AUDITLOG..."
      ~r/^([A-Z][a-z]{2}) {1,2}([0-9]{1,2}) ([0-9]{4}) ([0-9]{2}:[0-9]{2}:[0-9]{2})(?: (AM|PM))?(?:\.([0-9]{1,3}))? (UTC|[A-Z]{2,4}|TZ-[0-9]{1,2})?(?: *: *)? (.*)$/,
      ~r/^([A-Z][a-z]{2}) {1,2}([0-9]{1,2}) ([0-9]{2}:[0-9]{2}:[0-9]{2})(?: ([A-Z]{2,4}|TZ-[0-9]{1,2}))? ([0-9]{4}) (.*)$/,
      ~r/^([A-Z][a-z]{2}) {1,2}([0-9]{1,2}) ([0-9]{2}:[0-9]{2}:[0-9]{2})(?: ([A-Z]{2,4}|TZ-[0-9]{1,2}))? (.*)$/
    ]
    |> Enum.reduce_while({{:error, "TIMESTAMP invalid"}, syslog}, fn pattern, error ->
      case Regex.run(pattern, message, capture: :all_but_first) do
        [year1, month, day, time, "TZ" <> _ = tz, year2, message] ->
          year = get_year(year1, year2, Date.utc_today().year)

          {:ok, datetime, _} =
            DateTime.from_iso8601("#{year}-#{month(month)}-#{day}T#{time}#{tz(tz)}")

          {:halt, {message, Syslog.set_timestamp(syslog, datetime)}}

        [month, day, time, "", message] ->
          year = Date.utc_today().year
          {:ok, datetime, _} = DateTime.from_iso8601("#{year}-#{month(month)}-#{day}T#{time}Z")
          {:halt, {message, Syslog.set_timestamp(syslog, datetime)}}

        [year1, month, day, time, "", year2, message] ->
          year = get_year(year1, year2, Date.utc_today().year)
          {:ok, datetime, _} = DateTime.from_iso8601("#{year}-#{month(month)}-#{day}T#{time}Z")
          {:halt, {message, Syslog.set_timestamp(syslog, datetime)}}

        [month, day, year, time, am_pm, ms, tz, message] ->
          # Handle Cisco CUCM format: "Oct 14 2015 05:50:19 AM.484 UTC"
          # Convert 12-hour format to 24-hour if AM/PM is present
          time_24h = cond do
            am_pm == "PM" && !String.starts_with?(time, "12") ->
              "#{String.to_integer(String.slice(time, 0, 2)) + 12}#{String.slice(time, 2..-1//1)}"
            am_pm == "AM" && String.starts_with?(time, "12") ->
              "00#{String.slice(time, 2..-1//1)}"
            true ->
              time
          end

          # Add milliseconds if present
          time_with_ms = if ms, do: "#{time_24h}.#{ms}", else: time_24h

          # Set timezone or default to UTC
          timezone = cond do
            tz == "UTC" -> "Z"
            tz -> tz(tz)
            true -> "Z"
          end

          # Format the date properly with leading zeros for day
          padded_day = String.pad_leading(day, 2, "0")

          iso_datetime = "#{year}-#{month(month)}-#{padded_day}T#{time_with_ms}#{timezone}"

          case DateTime.from_iso8601(iso_datetime) do
            {:ok, datetime, _} ->
              {:halt, {message, Syslog.set_timestamp(syslog, datetime)}}
            {:error, _reason} ->
              # If milliseconds cause issues, try without them
              iso_datetime_no_ms = "#{year}-#{month(month)}-#{padded_day}T#{time_24h}#{timezone}"
              case DateTime.from_iso8601(iso_datetime_no_ms) do
                {:ok, datetime, _} ->
                  {:halt, {message, Syslog.set_timestamp(syslog, datetime)}}
                {:error, _} ->
                  {:cont, error}
              end
          end

        [year1, month, day, time, "TZ" <> _ = tz, message] ->
          year = get_year(year1, "", Date.utc_today().year)

          {:ok, datetime, _} =
            DateTime.from_iso8601("#{year}-#{month(month)}-#{day}T#{time}#{tz(tz)}")

          {:halt, {message, Syslog.set_timestamp(syslog, datetime)}}

        [month, day, time, tz, year2, message] ->
          year = get_year("", year2, Date.utc_today().year)
          datetime = to_datetime("#{year}-#{month(month)}-#{day}T#{time}", tz)
          {:halt, {message, Syslog.set_timestamp(syslog, datetime)}}

        [year1, month, day, time, tz, year2, message] ->
          year = get_year(year1, year2, Date.utc_today().year)
          datetime = to_datetime("#{year}-#{month(month)}-#{day}T#{time}", tz)
          {:halt, {message, Syslog.set_timestamp(syslog, datetime)}}

        nil ->
          {:cont, error}
      end
    end)
  end

  defp to_datetime(datetime_str, tz) do
    datetime_str
    |> NaiveDateTime.from_iso8601!()
    |> DateTime.from_naive(to_timezone(tz), Tzdata.TimeZoneDatabase)
    |> case do
      {:ok, datetime} ->
        DateTime.shift_zone!(datetime, @default_timezone)

      {:error, :time_zone_not_found} ->
        Logger.error("timezone (#{tz}) not found using #{@default_timezone}")
        to_datetime(datetime_str, @default_timezone)
    end
  end

  #  TODO add more timezones that are not included in tzdata
  defp to_timezone("BST"), do: "Europe/London"
  defp to_timezone("CST"), do: "Europe/Brussels"
  defp to_timezone("CET"), do: "Europe/Brussels"
  defp to_timezone(tz), do: tz

  defp get_year("", "", year), do: year
  defp get_year("", year, _), do: year
  defp get_year(year, _, _), do: year

  defp tz("TZ-" <> num), do: "-#{String.pad_leading(num, 2, "0")}:00"
  defp tz("TZ+" <> num), do: "+#{String.pad_leading(num, 2, "0")}:00"
  defp tz(tz), do: tz

  defp month("Jan"), do: "01"
  defp month("Feb"), do: "02"
  defp month("Mar"), do: "03"
  defp month("Apr"), do: "04"
  defp month("May"), do: "05"
  defp month("Jun"), do: "06"
  defp month("Jul"), do: "07"
  defp month("Aug"), do: "08"
  defp month("Sep"), do: "09"
  defp month("Oct"), do: "10"
  defp month("Nov"), do: "11"
  defp month("Dec"), do: "12"

  defp parse_timestamp({{:error, _} = error, syslog}), do: {error, syslog}

  defp parse_timestamp({"- " <> rest_message, syslog}), do: {rest_message, syslog}

  defp parse_timestamp({message, syslog}) do
    with [iso8601, rest_message] <- String.split(message, " ", parts: 2),
         {:ok, datetime, _tz} <- DateTime.from_iso8601(iso8601) do
      {rest_message, Syslog.set_timestamp(syslog, datetime)}
    else
      _ ->
        {{:error, "TIMESTAMP invalid"}, syslog}
    end
  end

  defp parse_string({{:error, _} = error, syslog}, _f, _name, _size), do: {error, syslog}

  defp parse_string({"- " <> rest_message, syslog}, _f, _name, _size), do: {rest_message, syslog}

  defp parse_string({message, syslog}, f, name, size) do
    # For structured messages that start with "%" or have a colon followed by spaces and "%",
    # skip hostname parsing as these are likely structured logs without a hostname
    if name == "HOSTNAME" && (
         String.starts_with?(message, "%") ||
         Regex.match?(~r/^: +%/, message) ||
         Regex.match?(~r/^[A-Z]{2,4} +: +%/, message)
       ) do
      # Skip hostname parsing for structured logs
      {message, syslog}
    else
      case String.split(message, " ", parts: 2) do
        [value, rest_message] when byte_size(value) in 1..size//1 ->
          {rest_message, f.(syslog, value)}

        _ ->
          {{:error, "#{name} invalid"}, syslog}
      end
    end
  end

  defp maybe_parse_ip_address({{:error, _} = error, syslog}), do: {error, syslog}

  defp maybe_parse_ip_address({message, syslog}) do
    pattern =
      ~r/^((?:25[0-5]|2[0-4][0-9]|1?[0-9][0-9]{1,2})(?:\.(?:25[0-5]|2[0-4][0-9]|1?[0-9]{1,2})){3})(.*)$/

    case Regex.run(pattern, message, capture: :all_but_first) do
      [ip, " " <> rest_message] ->
        {rest_message, Syslog.set_ip_address(syslog, ip)}

      nil ->
        {message, syslog}
    end
  end

  defp parse_old_process({{:error, _} = error, syslog}), do: {error, syslog}

  defp parse_old_process({message, syslog}) do
    case Regex.run(~r/^([^[]+)(?:\[([0-9]+)\])?: (.*)$/, message, capture: :all_but_first) do
      [app_name, "", message] ->
        {message, Syslog.set_app_name(syslog, app_name)}

      [app_name, process_id, message] ->
        syslog =
          syslog
          |> Syslog.set_app_name(app_name)
          |> Syslog.set_process_id(process_id)

        {message, syslog}

      nil ->
        {message, syslog}
    end
  end

  defp parse_old_structured_data({{:error, _} = error, syslog}), do: {error, syslog}

  defp parse_old_structured_data({"[" <> _ = message, syslog}) do
    case parse_structured_data({message, syslog}) do
      {{:error, "STRUCTURED-DATA invalid"}, _syslog} -> {message, syslog}
      other -> other
    end
  end

  # Handle Cisco CUCM structured data format: %[ key=value][ key=value]
  defp parse_old_structured_data({"%[" <> _ = message, syslog}) do
    parse_cisco_structured_data({message, syslog})
  end

  defp parse_old_structured_data({message, syslog}), do: {message, syslog}

  # Parse Cisco CUCM structured data format
  defp parse_cisco_structured_data({message, syslog}) do
    # Extract all [key=value] patterns
    pattern = ~r/\[\s*([^=\]]+)\s*=\s*([^\]]*)\]/

    # Find all matches in the message
    matches = Regex.scan(pattern, message)

    # Convert matches to a map of key-value pairs
    if matches != [] do
      params = Enum.reduce(matches, %{}, fn [_, key, value], acc ->
        Map.put(acc, String.trim(key), String.trim(value))
      end)

      # Add each key-value pair directly to the structured data
      syslog = Enum.reduce(params, syslog, fn {key, value}, acc ->
        # Use the key as the SD-ID and create a simple param with "value" as the key
        Syslog.add_structured_data(acc, key, %{"value" => value})
      end)

      # Find the end of the structured data section
      case Regex.run(~r/\]:\s*(.*)$/, message) do
        [_, remaining] -> {remaining, syslog}
        nil -> {message, syslog}
      end
    else
      {message, syslog}
    end
  end

  defp parse_structured_data({{:error, _} = error, syslog}), do: {error, syslog}

  defp parse_structured_data({"- " <> rest_message, syslog}), do: {rest_message, syslog}

  defp parse_structured_data({"[" <> rest_message, syslog}) do
    with {id, rest_message} <- simple_parse_sd_id(rest_message),
         {params, rest_message} <- simple_parse_params(rest_message) do
      if String.starts_with?(rest_message, "[") do
        parse_structured_data({rest_message, Syslog.add_structured_data(syslog, id, params)})
      else
        {rest_message, Syslog.add_structured_data(syslog, id, params)}
      end
    else
      _ -> {{:error, "STRUCTURED-DATA invalid"}, syslog}
    end
  end

  defp simple_parse_sd_id(message) do
    case String.split(message, " ", parts: 2) do
      [id, rest_message] when byte_size(id) in 1..32 -> {id, rest_message}
      _ -> :error
    end
  end

  defp simple_parse_params(message, params \\ %{}) do
    with [name, "\"" <> rest_message] when byte_size(name) in 1..32 <-
           String.split(message, "=", parts: 2),
         {value, rest_message} <- simple_parse_param_value(rest_message) do
      params = Map.put(params, name, value)

      case rest_message do
        "] " <> rest_message -> {params, rest_message}
        "]" <> rest_message -> {params, rest_message}
        " " <> rest_message -> simple_parse_params(rest_message, params)
      end
    else
      _ -> :error
    end
  end

  defp simple_parse_param_value(message, value \\ "")

  defp simple_parse_param_value("\\\\" <> rest_message, value),
    do: simple_parse_param_value(rest_message, value <> "\\")

  defp simple_parse_param_value("\\\"" <> rest_message, value),
    do: simple_parse_param_value(rest_message, value <> "\"")

  defp simple_parse_param_value("\\]" <> rest_message, value),
    do: simple_parse_param_value(rest_message, value <> "]")

  defp simple_parse_param_value("\"" <> rest_message, value), do: {value, rest_message}
  defp simple_parse_param_value("\\" <> _rest_message, _value), do: :error
  defp simple_parse_param_value("]" <> _rest_message, _value), do: :error
  defp simple_parse_param_value("", _value), do: :error

  defp simple_parse_param_value(<<ch::binary-size(1), rest_message::binary>>, value),
    do: simple_parse_param_value(rest_message, value <> ch)

  defp parse_message({{:error, _} = error, syslog}), do: {error, syslog}

  defp parse_message({"", syslog}), do: {"", syslog}

  defp parse_message({<<"BOM", message::binary>>, syslog}) do
    {"", Syslog.set_message(syslog, message)}
  end

  defp parse_message({message, syslog}) do
    {"", Syslog.set_message(syslog, message)}
  end

  defp parse_old_message({{:error, "PRI " <> _}, syslog}, message) do
    {"", Syslog.set_message(syslog, message)}
  end

  # Handle case where message is an error tuple from timestamp parsing
  defp parse_old_message({{:error, _error_message}, syslog}, complete_message) do
    # Use the complete original message as the message content
    {"", Syslog.set_message(syslog, complete_message)}
  end

  defp parse_old_message({message, syslog}, _complete_message) do
    {"", Syslog.set_message(syslog, message)}
  end
end
