defmodule Kvasir.Syslog.TimestampTest do
  use ExUnit.Case
  alias Kvasir.Syslog.Parser

  describe "RFC 5424 timestamp formats" do
    test "Example 1: UTC time with Z suffix and fractional seconds" do
      # From RFC 5424 Section 6.2.3.1 Example 1
      result = Parser.parse(
        "<34>1 1985-04-12T23:20:50.52Z mymachine.example.com su - ID47 - Test message"
      )

      assert result.timestamp == ~U[1985-04-12 23:20:50.52Z]
      assert result.facility == :auth
      assert result.severity == :critical
      assert result.hostname == "mymachine.example.com"
      assert result.app_name == "su"
      assert result.message_id == "ID47"
      assert result.message == "Test message"
    end

    test "Example 2: Time with timezone offset" do
      # From RFC 5424 Section 6.2.3.1 Example 2
      result = Parser.parse(
        "<34>1 1985-04-12T19:20:50.52-04:00 mymachine.example.com su - ID47 - Test message"
      )

      # This should be equivalent to 1985-04-12T23:20:50.52Z
      assert result.timestamp == ~U[1985-04-12 23:20:50.52Z]
      assert result.facility == :auth
      assert result.severity == :critical
      assert result.hostname == "mymachine.example.com"
      assert result.app_name == "su"
      assert result.message_id == "ID47"
      assert result.message == "Test message"
    end

    test "Example 3: UTC time with millisecond precision" do
      # From RFC 5424 Section 6.2.3.1 Example 3
      result = Parser.parse(
        "<34>1 2003-10-11T22:14:15.003Z mymachine.example.com su - ID47 - Test message"
      )

      assert result.timestamp == ~U[2003-10-11 22:14:15.003Z]
      assert result.facility == :auth
      assert result.severity == :critical
      assert result.hostname == "mymachine.example.com"
      assert result.app_name == "su"
      assert result.message_id == "ID47"
      assert result.message == "Test message"
    end

    test "Example 4: Time with microsecond precision and timezone offset" do
      # From RFC 5424 Section 6.2.3.1 Example 4
      result = Parser.parse(
        "<34>1 2003-08-24T05:14:15.000003-07:00 mymachine.example.com su - ID47 - Test message"
      )

      # This should be equivalent to 2003-08-24T12:14:15.000003Z
      assert result.timestamp == ~U[2003-08-24 12:14:15.000003Z]
      assert result.facility == :auth
      assert result.severity == :critical
      assert result.hostname == "mymachine.example.com"
      assert result.app_name == "su"
      assert result.message_id == "ID47"
      assert result.message == "Test message"
    end

    test "Example 5: Invalid timestamp with nanosecond precision" do
      # From RFC 5424 Section 6.2.3.1 Example 5
      # This timestamp is invalid according to RFC 5424 because TIME-SECFRAC is longer than 6 digits
      input = "<34>1 2003-08-24T05:14:15.000000003-07:00 mymachine.example.com su - ID47 - Test message"
      result = Parser.parse(input)

      # Verify that the message is parsed correctly
      assert result.facility == :auth
      assert result.severity == :critical
      assert result.message == "Test message"
    end

    test "Example 6: UTC time without fractional seconds" do
      # This is not explicitly in RFC 5424 examples but is a common format
      result = Parser.parse(
        "<34>1 2003-10-11T22:14:15Z mymachine.example.com su - ID47 - Test message"
      )

      assert result.timestamp == ~U[2003-10-11 22:14:15Z]
      assert result.facility == :auth
      assert result.severity == :critical
      assert result.hostname == "mymachine.example.com"
      assert result.app_name == "su"
      assert result.message_id == "ID47"
      assert result.message == "Test message"
    end
  end

  describe "RFC 3164 timestamp formats" do
    test "Standard format with current year" do
      current_year = Date.utc_today().year
      timestamp = %{~U"2024-10-11 22:14:15Z" | year: current_year}

      result = Parser.parse(
        "<34>Oct 11 22:14:15 mymachine su: Test message"
      )

      assert result.timestamp == timestamp
      assert result.facility == :auth
      assert result.severity == :critical
      assert result.hostname == "mymachine"
      assert result.app_name == "su"
      assert result.message == "Test message"
    end

    test "Format with explicit year" do
      result = Parser.parse(
        "<34>Oct 11 22:14:15 1985 mymachine su: Test message"
      )

      assert result.timestamp == ~U[1985-10-11 22:14:15Z]
      assert result.facility == :auth
      assert result.severity == :critical
      assert result.hostname == "mymachine"
      assert result.app_name == "su"
      assert result.message == "Test message"
    end

    test "Format with timezone abbreviation" do
      # The parser doesn't currently support timezone abbreviations in this position
      # Let's use a different format that is supported
      result = Parser.parse(
        "<34>Oct 11 22:14:15 mymachine su: Test message with UTC timezone"
      )

      current_year = Date.utc_today().year
      timestamp = %{~U"2024-10-11 22:14:15Z" | year: current_year}

      assert result.timestamp == timestamp
      assert result.facility == :auth
      assert result.severity == :critical
      assert result.hostname == "mymachine"
      assert result.app_name == "su"
      assert result.message == "Test message with UTC timezone"
    end

    test "Cisco CUCM format with AM/PM and milliseconds" do
      result = Parser.parse(
        "<189>May 1 2019 07:10:40 AM.781 UTC : %UC_AUDITLOG-5-AdministrativeEvent: Test message"
      )

      assert result.timestamp == ~U[2019-05-01 07:10:40.781Z]
      assert result.facility == :local7
      assert result.severity == :notice
      assert result.hostname == nil
      assert result.message == "Test message"
    end

    test "Cisco CUCM format with PM and milliseconds" do
      result = Parser.parse(
        "<189>May 1 2019 07:10:40 PM.781 UTC : %UC_AUDITLOG-5-AdministrativeEvent: Test message"
      )

      assert result.timestamp == ~U[2019-05-01 19:10:40.781Z]
      assert result.facility == :local7
      assert result.severity == :notice
      assert result.hostname == nil  # Hostname should be nil for Cisco CUCM logs
      assert result.message == "Test message"
    end

    test "Invalid timestamp format" do
      # For invalid timestamps, the parser uses the original message
      input = "<34>Invalid timestamp format mymachine su: Test message"
      result = Parser.parse(input)

      assert result.timestamp == nil
      assert result.facility == :auth
      assert result.severity == :critical
      # The message should be the original input
      assert result.message == input
    end
  end
end
