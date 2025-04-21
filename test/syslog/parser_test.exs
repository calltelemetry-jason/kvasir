defmodule Kvasir.Syslog.ParserTest do
  use ExUnit.Case
  alias Kvasir.Syslog
  alias Kvasir.Syslog.Parser

  describe "rfc3164 examples" do
    test "5.4. example 1" do
      current_year = Date.utc_today().year
      timestamp = %{~U"2024-10-11 22:14:15Z" | year: current_year}

      assert %Syslog{
               app_name: "su",
               facility: :auth,
               hostname: "mymachine",
               message: "'su root' failed for lonvick on /dev/pts/8",
               rfc: :rfc3164,
               severity: :critical,
               timestamp: timestamp
             } ==
               Parser.parse(
                 "<34>Oct 11 22:14:15 mymachine su: 'su root' failed for lonvick" <>
                   " on /dev/pts/8"
               )
    end

    test "5.4. example 2" do
      assert %Syslog{
               message: "Use the BFG!",
               rfc: :rfc3164
             } == Parser.parse("Use the BFG!")
    end

    test "5.4. example 3" do
      assert %Syslog{
               app_name: "myproc",
               facility: :local4,
               hostname: "mymachine",
               message:
                 "%% It's time to make the do-nuts.  %%  Ingredients: Mix=OK, " <>
                   "Jelly=OK #Devices: Mixer=OK, Jelly_Injector=OK, Frier=OK # " <>
                   "Transport: Conveyer1=OK, Conveyer2=OK # %%",
               process_id: "10",
               rfc: :rfc3164,
               severity: :notice,
               timestamp: ~U[1987-08-24 03:34:00Z]
             } ==
               Parser.parse(
                 "<165>Aug 24 05:34:00 CST 1987 mymachine myproc[10]: %% It's " <>
                   "time to make the do-nuts.  %%  Ingredients: Mix=OK, Jelly=OK #" <>
                   "Devices: Mixer=OK, Jelly_Injector=OK, Frier=OK # Transport: " <>
                   "Conveyer1=OK, Conveyer2=OK # %%"
               )
    end

    test "5.4. example 4" do
      assert %Syslog{
               app_name: "sched",
               facility: :kernel,
               hostname: "scapegoat.dmz.example.org",
               ip_address: "10.1.2.3",
               message: "That's All Folks!",
               process_id: "0",
               rfc: :rfc3164,
               severity: :emergency,
               timestamp: ~U[1990-10-22 16:52:01Z]
             } ==
               Parser.parse(
                 "<0>1990 Oct 22 10:52:01 TZ-6 scapegoat.dmz.example.org 10.1.2.3 " <>
                   "sched[0]: That's All Folks!"
               )
    end
  end

  describe "rfc5424 examples" do
    test "6.5. example 1" do
      assert %Syslog{
               app_name: "su",
               facility: :auth,
               hostname: "mymachine.example.com",
               message: "'su root' failed for lonvick on /dev/pts/8",
               message_id: "ID47",
               severity: :critical,
               timestamp: ~U[2003-10-11 22:14:15.003Z]
             } ==
               Parser.parse(
                 "<34>1 2003-10-11T22:14:15.003Z mymachine.example.com su - ID47 - BOM'su root' failed for lonvick on /dev/pts/8"
               )
    end

    test "6.5. example 2" do
      assert %Syslog{
               app_name: "myproc",
               facility: :local4,
               hostname: "192.0.2.1",
               message: "%% It's time to make the do-nuts.",
               process_id: "8710",
               severity: :notice,
               timestamp: ~U[2003-08-24 12:14:15.000003Z]
             } ==
               Parser.parse(
                 "<165>1 2003-08-24T05:14:15.000003-07:00 192.0.2.1 myproc 8710 - - %% It's time to make the do-nuts."
               )
    end

    test "6.5. example 3" do
      assert %Syslog{
               app_name: "evntslog",
               facility: :local4,
               hostname: "mymachine.example.com",
               message: "An application event log entry...",
               message_id: "ID47",
               severity: :notice,
               structured_data: %{
                 "exampleSDID@32473" => %{
                   "eventID" => "1011",
                   "eventSource" => "Application",
                   "iut" => "3"
                 }
               },
               timestamp: ~U[2003-10-11 22:14:15.003Z]
             } ==
               Parser.parse(
                 ~s|<165>1 2003-10-11T22:14:15.003Z mymachine.example.com evntslog - ID47 [exampleSDID@32473 iut="3" eventSource="Application" eventID="1011"] BOMAn application event log entry...|
               )
    end

    test "6.5. example 4" do
      assert %Syslog{
               app_name: "evntslog",
               facility: :local4,
               hostname: "mymachine.example.com",
               message_id: "ID47",
               severity: :notice,
               structured_data: %{
                 "examplePriority@32473" => %{"class" => "high"},
                 "exampleSDID@32473" => %{
                   "eventID" => "1011",
                   "eventSource" => "Application",
                   "iut" => "3"
                 }
               },
               timestamp: ~U[2003-10-11 22:14:15.003Z]
             } ==
               Parser.parse(
                 ~s|<165>1 2003-10-11T22:14:15.003Z mymachine.example.com evntslog - ID47 [exampleSDID@32473 iut="3" eventSource="Application" eventID="1011"][examplePriority@32473 class="high"]|
               )
    end
  end

  describe "cisco cucm format" do
    test "parses cisco cucm timestamp format with structured data" do
      # Parse a Cisco CUCM log with structured data
      result = Parser.parse(
        "<189>May 1 2019 07:10:40 AM.781 UTC :  %UC_AUDITLOG-5-AdministrativeEvent: %[ UserID =administrator][ ClientAddress =10.110.111.230][ Severity =5][ EventType =GeneralConfigurationUpdate][ ResourceAccessed=CUCMAdmin][ EventStatus =Success][ CompulsoryEvent =No][ AuditCategory =AdministrativeEvent][ ComponentID =Cisco CUCM Administration][ AuditDetails =record in table device, with key field name = SEP0000311107A5 deleted][App ID=Cisco Tomcat][Cluster ID=][Node ID=CUCM12PUB]: Audit Event is generated by this application"
      )

      # Verify basic fields
      assert result.facility == :local7
      assert result.severity == :notice
      assert result.rfc == :rfc3164
      assert result.timestamp == ~U[2019-05-01 07:10:40.781Z]
      assert result.hostname == nil  # Hostname should be nil for Cisco CUCM logs

      # Verify structured data is parsed correctly
      assert Map.has_key?(result.structured_data, "UserID")
      assert Map.has_key?(result.structured_data, "ClientAddress")
      assert Map.has_key?(result.structured_data, "Severity")

      # Verify specific structured data fields
      assert result.structured_data["UserID"]["value"] == "administrator"
      assert result.structured_data["ClientAddress"]["value"] == "10.110.111.230"
      assert result.structured_data["Severity"]["value"] == "5"
      assert result.structured_data["EventType"]["value"] == "GeneralConfigurationUpdate"
      assert result.structured_data["ResourceAccessed"]["value"] == "CUCMAdmin"
      assert result.structured_data["EventStatus"]["value"] == "Success"
      assert result.structured_data["CompulsoryEvent"]["value"] == "No"
      assert result.structured_data["AuditCategory"]["value"] == "AdministrativeEvent"
      assert result.structured_data["ComponentID"]["value"] == "Cisco CUCM Administration"
      assert result.structured_data["Node ID"]["value"] == "CUCM12PUB"
      assert result.structured_data["AuditDetails"]["value"] == "record in table device, with key field name = SEP0000311107A5 deleted"

      # Verify the remaining message
      assert result.message == "Audit Event is generated by this application"
    end

    test "handles Cisco CUCM format with additional number after PRI" do
      # This format has an additional number after the PRI value (8103:)
      result = Parser.parse(
        "<189>8103: Apr 20 2025 10:45:20 PM.601 UTC :  %UC_AUDITLOG-5-AdministrativeEvent: %[ UserID =admin][ ClientAddress =195.97.62.73][ Severity =5][ EventType =GeneralConfigurationUpdate][ ResourceAccessed=CUCMAdmin][ EventStatus =Success][ CompulsoryEvent =No][ AuditCategory =AdministrativeEvent][ ComponentID =Cisco CUCM Administration][ AuditDetails =record in table device, with key field name = SEPDA36544DDB40 deleted][App ID=Cisco Tomcat][Cluster ID=][Node ID=CUCM11PUB]: Audit Event is generated by this application"
      )

      # Verify basic fields
      assert result.facility == :local7
      assert result.severity == :notice
      assert result.rfc == :rfc3164
      assert result.timestamp == ~U[2025-04-20 22:45:20.601Z]
      assert result.hostname == nil  # Hostname should be nil for Cisco CUCM logs

      # Verify structured data is parsed correctly
      assert Map.has_key?(result.structured_data, "UserID")
      assert Map.has_key?(result.structured_data, "ClientAddress")

      # Verify specific structured data fields
      assert result.structured_data["UserID"]["value"] == "admin"
      assert result.structured_data["ClientAddress"]["value"] == "195.97.62.73"

      # Verify the remaining message
      assert result.message == "Audit Event is generated by this application"
    end

    test "handles invalid timestamp gracefully" do
      # This test ensures that even with an invalid timestamp, the parser returns a valid Syslog struct
      # with a string message, not an error tuple
      result = Parser.parse(
        "<189>8103: Invalid timestamp format :  %UC_AUDITLOG-5-AdministrativeEvent: Message content"
      )

      # Verify basic fields
      assert result.facility == :local7
      assert result.severity == :notice
      assert result.rfc == :rfc3164
      assert result.timestamp == nil  # Timestamp should be nil for invalid timestamp

      # Most importantly, the message should be a string, not an error tuple
      assert is_binary(result.message)
      assert result.message =~ "Invalid timestamp format"
    end
  end

  describe "rfc5424 timestamp formats" do
    test "Example 1: UTC time with Z suffix" do
      result = Parser.parse(
        "<34>1 1985-04-12T23:20:50.52Z mymachine.example.com su - ID47 - 'su root' failed for lonvick on /dev/pts/8"
      )

      assert result.timestamp == ~U[1985-04-12 23:20:50.52Z]
    end

    test "Example 2: Time with timezone offset" do
      result = Parser.parse(
        "<34>1 1985-04-12T19:20:50.52-04:00 mymachine.example.com su - ID47 - 'su root' failed for lonvick on /dev/pts/8"
      )

      # This should be equivalent to 1985-04-12T23:20:50.52Z
      assert result.timestamp == ~U[1985-04-12 23:20:50.52Z]
    end

    test "Example 3: UTC time with millisecond precision" do
      result = Parser.parse(
        "<34>1 2003-10-11T22:14:15.003Z mymachine.example.com su - ID47 - 'su root' failed for lonvick on /dev/pts/8"
      )

      assert result.timestamp == ~U[2003-10-11 22:14:15.003Z]
    end

    test "Example 4: Time with microsecond precision and timezone offset" do
      result = Parser.parse(
        "<34>1 2003-08-24T05:14:15.000003-07:00 mymachine.example.com su - ID47 - 'su root' failed for lonvick on /dev/pts/8"
      )

      # This should be equivalent to 2003-08-24T12:14:15.000003Z
      assert result.timestamp == ~U[2003-08-24 12:14:15.000003Z]
    end

    test "Example 5: Invalid timestamp with nanosecond precision" do
      # This timestamp is invalid according to RFC 5424 because TIME-SECFRAC is longer than 6 digits
      # The parser should handle this gracefully
      input = "<34>1 2003-08-24T05:14:15.000000003-07:00 mymachine.example.com su - ID47 - 'su root' failed for lonvick on /dev/pts/8"
      result = Parser.parse(input)

      # Verify that the message is parsed correctly
      assert result.facility == :auth
      assert result.severity == :critical
      assert result.message == "'su root' failed for lonvick on /dev/pts/8"
    end
  end
end
