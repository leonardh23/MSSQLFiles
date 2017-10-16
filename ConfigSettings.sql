--------------------------------------------------------------------
--------------------------------------------------------------------
------- Author: Ajay Garg
------- Date: 09/14/2010
------- Purpose: SQL Server Configuration settings for PRODUCTION ENVIRONMENT ONLY (US, EU).
-------                                                ===========================
------- The database mail will be configured accordingly.
--------------------------------------------------------------------
--------------------------------------------------------------------
--------------------------------------------------------------------
set nocount on
use master
go
-- check SQL Server version
select serverproperty('ProductVersion') 'ProductVersion', 
		serverproperty('ProductLevel') 'ProductLevel', 
		serverproperty('Edition') 'Edition'
GO
print 'Configuring system wide settings...'
go
exec sp_configure 'show', 1
go
reconfigure with override
go
--These 2 affinity values are likely to be different for this environment
--sp_configure 'affinity mask', '65534'
--sp_configure 'affinity I/O mask', '65534'
exec sp_configure 'remote query timeout (s)', '0'
exec sp_configure 'Agent XPs', 1
exec sp_configure 'clr enabled', 1
exec sp_configure 'remote admin connections', 1
exec sp_configure 'Database Mail XPs', 1
exec sp_configure 'Ole Automation Procedures', 1
exec sp_configure 'xp_cmdshell', 1
exec sp_configure 'max degree of parallelism', 1
exec sp_configure 'max text repl size', -1
go
declare @SQLEdition varchar(64)
select @SQLEdition = cast(ServerProperty('Edition') as varchar)
if @SQLEdition like '%Enterprise%' or @SQLEdition like '%Developer%' 
OR ((@@MicrosoftVersion / 0x01000000) > 10 AND (@SQLEdition NOT LIKE '%web%' AND @SQLEdition NOT LIKE '%express%'))
begin
	exec sp_configure 'backup compression default', 1
end
go

reconfigure with override
go

print 'Setting up trace flags at start up...'
declare @ParameterTbl table(ParameterValue varchar(20))
insert @ParameterTbl values('-T1117')
insert @ParameterTbl values('-T1118')

declare 
	@ParameterValue varchar(20),
	@Argument_Number int,
	@Argument varchar(20),
	@Reg_Hive varchar(max),
	@cmd varchar(max)
IF CAST(SERVERPROPERTY('ProductVersion') AS VARCHAR) BETWEEN '10.5' AND '13' -- SQL SERVER 2008 R2 thru 2014
begin
	select @ParameterValue = min(ParameterValue) from @ParameterTbl
	while @ParameterValue is not null
	begin
		select @ParameterValue '@ParameterValue'
		if not exists (
			select * 
			from sys.dm_server_registry 
			where value_name like 'SQLArg%' 
			and value_data = @ParameterValue)
		begin
			select 
				@Reg_Hive = substring(registry_key, len('HKLM\')+1, len(registry_key)),
				@Argument_Number = max(convert(int, right(value_name, 1)))+1
			from sys.dm_server_registry
			where value_name like 'SQLArg%' 
			group by substring(registry_key, len('HKLM\')+1, len(registry_key)) 

			set @Argument = 'SQLArg'+convert(varchar(1), @Argument_Number)

			set @cmd='master..xp_regwrite ''HKEY_LOCAL_MACHINE'', '''+@Reg_Hive+''', '''+@Argument+''', ''REG_SZ'', '''+@ParameterValue+''''
			select @Argument, @Reg_Hive, @cmd
			exec(@cmd)
		end 

		select @ParameterValue = min(ParameterValue) 
		from @ParameterTbl
		where ParameterValue > @ParameterValue
	end
end
go

print 'Setting default folders for mdf and ldf files...'
go
EXEC xp_instance_regwrite N'HKEY_LOCAL_MACHINE', N'Software\Microsoft\MSSQLServer\MSSQLServer', N'DefaultData', REG_SZ, N'E:\MSSQL\Data'
GO
EXEC xp_instance_regwrite N'HKEY_LOCAL_MACHINE', N'Software\Microsoft\MSSQLServer\MSSQLServer', N'DefaultLog', REG_SZ, N'L:\MSSQL\Logs'
GO

print 'Setting # of SQL Server errorlog files to 45...'
go
EXEC xp_instance_regwrite N'HKEY_LOCAL_MACHINE', N'Software\Microsoft\MSSQLServer\MSSQLServer', N'NumErrorLogs', REG_DWORD, 45
GO

print 'Creating dbadmin database...'
go
declare @cmd varchar(1000)
declare @tbl table (rowdata varchar(200))
insert @tbl exec master..xp_cmdshell 'dir T:\admin\dbbackups\dbadmin_install.bak'

--select * from @tbl
if exists(select * from @tbl where rowdata like 'File Not Found')
begin
	Raiserror ('dbadmin backup not found at the location...', 16, 1)
end
else
begin
	restore filelistonly from disk = 'T:\admin\dbbackups\dbadmin_install.bak'

	restore database dbadmin from disk = 'T:\admin\dbbackups\dbadmin_install.bak' with stats = 5, replace,
	move 'dbadmin_Data' to 'E:\MSSQL\Data\dbadmin_Data.MDF',
	move 'dbadmin_Log' to 'L:\MSSQL\Logs\dbadmin_Log.LDF'

	select @cmd = 'use dbadmin; EXEC dbo.sp_changedbowner @loginame = N''sa'', @map = false'
	exec(@cmd)

	print 'Setting max memory for SQL Server to 75%...'
	select @cmd = 'exec dbadmin.dbo.pr_FixMemory 75'
	exec(@cmd)
end
GO


USE [master]
GO
print 'Setting up end point for mirroring...'
go

CREATE ENDPOINT HA_Mirroring
	AUTHORIZATION [sa]
    STATE=STARTED 
    AS TCP (LISTENER_PORT=5022) 
    FOR DATABASE_MIRRORING (ROLE=ALL)
GO

Use MSDB
GO
print 'Setting SQL Agent history settings...'
go

EXEC msdb.dbo.sp_set_sqlagent_properties @jobhistory_max_rows=-1, 
		@jobhistory_max_rows_per_job=-1
GO

print 'Setting up database mail...'
go

DECLARE @Domain varchar(100), @key varchar(100)
DECLARE @profile_name VARCHAR(50), @account_name VARCHAR(50), @description VARCHAR(50)
DECLARE @display_name VARCHAR(50), @mailserver_name VARCHAR(50), @user VARCHAR(50)
SET @key = 'SYSTEM\ControlSet001\Services\Tcpip\Parameters\'
SET @user = SUSER_NAME()
EXEC master..xp_regread @rootkey='HKEY_LOCAL_MACHINE', @key=@key,@value_name='Domain',@value=@Domain OUTPUT 
SELECT 'Server Name: '+@@servername + ', Domain Name: '+@Domain 
if CHARINDEX('eutrips', @Domain, 1) > 0 
BEGIN
	PRINT 'eutrips' 
	SELECT @profile_name = 'LondonDBMail',
			@account_name = 'LondonSQLJob',
			@description = 'London SQL Job Status Mail',
			@display_name = 'HomeAwayDBAGroup',
			@mailserver_name = 'mailq.eutrips.live'

	if not exists(select 1 from master.dbo.syslogins where name = 'EUTRIPS\sqlservices')
	begin
		create login [EUTRIPS\sqlservices] from windows with default_database = master, default_language = us_english
		EXEC sys.sp_addsrvrolemember @loginame = N'EUTRIPS\sqlservices', @rolename = N'sysadmin'
	end
	if not exists(select 1 from master.dbo.syslogins where name = 'HOMEAWAY0\sqlservices')
	begin
		create login [HOMEAWAY0\sqlservices] from windows with default_database = master, default_language = us_english
		EXEC sys.sp_addsrvrolemember @loginame = N'HOMEAWAY0\sqlservices', @rolename = N'sysadmin'
	end
END
ELSE if CHARINDEX('homeaway', @Domain, 1) > 0 
BEGIN
	PRINT 'homeaway' 
	SELECT @profile_name = 'HomeAwayDatabaseMail',
			@account_name = 'HomeAwayDBAs',
			@description = 'Mail account for HomeAway DBAs',
			@display_name = 'HomeAway Automated Mailer',
			@mailserver_name = 'mailq.aus1.homeaway.live'

	if not exists(select 1 from master.dbo.syslogins where name = 'HOMEAWAY0\sqlservices')
	begin
		create login [HOMEAWAY0\sqlservices] from windows with default_database = master, default_language = us_english
		EXEC sys.sp_addsrvrolemember @loginame = N'HOMEAWAY0\sqlservices', @rolename = N'sysadmin'
	end
END
ELSE if CHARINDEX('wvrgroup', @Domain, 1) > 0 
BEGIN
	PRINT 'wvrgroup' 
	SELECT @profile_name = 'HomeAwayDatabaseMail',
			@account_name = 'HomeAwayDBAs',
			@description = 'Mail account for HomeAway DBAs',
			@display_name = 'HomeAway Automated Mailer',
			@mailserver_name = 'mailq.wvrgroup.internal'

	if not exists(select 1 from master.dbo.syslogins where name = 'WVRGROUP\sqlservices')
	begin
		create login [WVRGROUP\sqlservices] from windows with default_database = master, default_language = us_english
		EXEC sys.sp_addsrvrolemember @loginame = N'WVRGROUP\sqlservices', @rolename = N'sysadmin'
	end
	if not exists(select 1 from master.dbo.syslogins where name = 'HOMEAWAY0\sqlservices')
	begin
		create login [HOMEAWAY0\sqlservices] from windows with default_database = master, default_language = us_english
		EXEC sys.sp_addsrvrolemember @loginame = N'HOMEAWAY0\sqlservices', @rolename = N'sysadmin'
	end
END
ELSE if CHARINDEX('hahosting.local', @Domain, 1) > 0 
BEGIN
	PRINT 'hahosting.local' 
	SELECT @profile_name = 'HomeAwayDatabaseMail',
			@account_name = 'HomeAwayDBAs',
			@description = 'Mail account for HomeAway DBAs',
			@display_name = 'HomeAway Automated Mailer',
			@mailserver_name = 'mailq.wvrgroup.internal'

	if not exists(select 1 from master.dbo.syslogins where name = 'HAHOSTING\sqlservices')
	begin
		create login [HAHOSTING\sqlservices] from windows with default_database = master, default_language = us_english
		EXEC sys.sp_addsrvrolemember @loginame = N'HAHOSTING\sqlservices', @rolename = N'sysadmin'
	end
	if not exists(select 1 from master.dbo.syslogins where name = 'HOMEAWAY0\sqlservices')
	begin
		create login [HOMEAWAY0\sqlservices] from windows with default_database = master, default_language = us_english
		EXEC sys.sp_addsrvrolemember @loginame = N'HOMEAWAY0\sqlservices', @rolename = N'sysadmin'
	end
END

Execute msdb.dbo.sysmail_add_profile_sp 
	@profile_name = @profile_name 
	,@description = 'Desc'

Execute msdb.dbo.sysmail_add_account_sp
	@account_name = @account_name
	,@description = @description
	,@email_address = 'dbops@homeaway.com'
	,@display_name = @display_name
	,@mailserver_name = @mailserver_name
	,@mailserver_type = 'SMTP'

Execute msdb.dbo.sysmail_add_profileaccount_sp
	@profile_name = @profile_name
	,@account_name = @account_name
	,@sequence_number = 1

EXECUTE msdb.dbo.sysmail_configure_sp 'AccountRetryAttempts', '3'
EXECUTE msdb.dbo.sysmail_configure_sp 'MaxFileSize', '104857600'	-- 100MB

-- Now test
declare @subject varchar(100)
select @subject = 'Testing DBMail from server: '+@@servername
Execute msdb.dbo.sp_send_dbmail 
@profile_name = @profile_name
,@recipients = 'dbops@homeaway.com'
--,@copy_recipients = ''
,@subject = @subject
,@body = @user
go

-- Status check
use msdb
go

select * from msdb.dbo.sysmail_mailitems where sent_date > CONVERT(varchar(10), getdate(), 101)
select * from msdb.dbo.sysmail_log where log_date > CONVERT(varchar(10), getdate(), 101)
select * from msdb.dbo.sysmail_send_retries where last_send_attempt_date > CONVERT(varchar(10), getdate(), 101)
select * from msdb.dbo.sysmail_server
go

-- setup MSDTC
EXEC dbadmin.dbo.pr_CheckDTC @ReportFix = 'F', @Show = 0
go

print 'Creating override stored procedures in msdb...'
go

USE [msdb]
GO

CREATE PROCEDURE [dbo].[sp_add_category_override]
  @class VARCHAR(8)   = 'JOB',   -- JOB or ALERT or OPERATOR
  @type  VARCHAR(12)  = 'LOCAL', -- LOCAL or MULTI-SERVER (for JOB) or NONE otherwise
  @name  sysname
WITH EXECUTE AS OWNER
AS
BEGIN
   EXEC dbo.sp_add_category
  @class,
  @type,
  @name
END
GO

GRANT EXECUTE ON [dbo].[sp_add_category_override] TO [SQLAgentOperatorRole]
GO

CREATE PROCEDURE [dbo].[sp_add_job_override]
	@job_name                     sysname,
	@enabled                      TINYINT          = 1,
	@description                  NVARCHAR(512)    = NULL,
	@start_step_id                INT              = 1,
	@category_name                sysname          = NULL,
	@category_id                  INT              = NULL,
	@owner_login_name             sysname          = NULL,
	@notify_level_eventlog        INT              = 2,
	@notify_level_email           INT              = 0,
	@notify_level_netsend         INT              = 0,
	@notify_level_page            INT              = 0,
	@notify_email_operator_name   sysname          = NULL,
	@notify_netsend_operator_name sysname          = NULL,
	@notify_page_operator_name    sysname          = NULL,
	@delete_level                 INT              = 0,
	@job_id                       UNIQUEIDENTIFIER = NULL OUTPUT,
	@originating_server           sysname           = NULL
WITH EXECUTE AS OWNER
AS
BEGIN
   EXEC dbo.sp_add_job
	@job_name,
	@enabled,
	@description,
	@start_step_id,
	@category_name,
	@category_id,
	@owner_login_name,
	@notify_level_eventlog,
	@notify_level_email,
	@notify_level_netsend,
	@notify_level_page,
	@notify_email_operator_name,
	@notify_netsend_operator_name,
	@notify_page_operator_name,
	@delete_level,
	@job_id OUTPUT,
	@originating_server
END
GO

GRANT EXECUTE ON [dbo].[sp_add_job_override] TO [SQLAgentOperatorRole]
GO

CREATE PROCEDURE [dbo].[sp_add_jobserver_override]
  @job_id         UNIQUEIDENTIFIER = NULL, -- Must provide either this or job_name
  @job_name       sysname          = NULL, -- Must provide either this or job_id
  @server_name    sysname         = NULL, -- if NULL will default to serverproperty('ServerName')
  @automatic_post BIT = 1                  -- Flag for SEM use only
WITH EXECUTE AS OWNER
AS
BEGIN
   EXEC dbo.sp_add_jobserver
  @job_id,
  @job_name,
  @server_name,
  @automatic_post
END
GO

GRANT EXECUTE ON [dbo].[sp_add_jobserver_override] TO [SQLAgentOperatorRole]
GO

CREATE PROCEDURE [dbo].[sp_add_jobstep_override]
  @job_id                UNIQUEIDENTIFIER = NULL,   -- Must provide either this or job_name
  @job_name              sysname          = NULL,   -- Must provide either this or job_id
  @step_id               INT              = NULL,   -- The proc assigns a default
  @step_name             sysname,
  @subsystem             NVARCHAR(40)     = N'TSQL',
  @command               NVARCHAR(max)   = NULL,   
  @additional_parameters NVARCHAR(max)    = NULL,
  @cmdexec_success_code  INT              = 0,
  @on_success_action     TINYINT          = 1,      -- 1 = Quit With Success, 2 = Quit With Failure, 3 = Goto Next Step, 4 = Goto Step
  @on_success_step_id    INT              = 0,
  @on_fail_action        TINYINT          = 2,      -- 1 = Quit With Success, 2 = Quit With Failure, 3 = Goto Next Step, 4 = Goto Step
  @on_fail_step_id       INT              = 0,
  @server                sysname      = NULL,
  @database_name         sysname          = NULL,
  @database_user_name    sysname          = NULL,
  @retry_attempts        INT              = 0,      -- No retries
  @retry_interval        INT              = 0,      -- 0 minute interval
  @os_run_priority       INT              = 0,      -- -15 = Idle, -1 = Below Normal, 0 = Normal, 1 = Above Normal, 15 = Time Critical)
  @output_file_name      NVARCHAR(200)    = NULL,
  @flags                 INT              = 0,       -- 0 = Normal, 
                                                     -- 1 = Encrypted command (read only), 
                                                     -- 2 = Append output files (if any), 
                                                     -- 4 = Write TSQL step output to step history,                                            
                                                     -- 8 = Write log to table (overwrite existing history), 
                                                     -- 16 = Write log to table (append to existing history)
                                                     -- 32 = Write all output to job history
                                                     -- 64 = Create a Windows event to use as a signal for the Cmd jobstep to abort
  @proxy_id                 INT                = NULL,
  @proxy_name               sysname          = NULL,
  -- mutual exclusive; must specify only one of above 2 parameters to 
  -- identify the proxy. 
  @step_uid UNIQUEIDENTIFIER = NULL OUTPUT
WITH EXECUTE AS OWNER
AS
BEGIN
   EXEC dbo.sp_add_jobstep
  @job_id,
  @job_name,
  @step_id,
  @step_name,
  @subsystem,
  @command,   
  @additional_parameters,
  @cmdexec_success_code,
  @on_success_action,
  @on_success_step_id,
  @on_fail_action,
  @on_fail_step_id,
  @server,
  @database_name,
  @database_user_name,
  @retry_attempts,
  @retry_interval,
  @os_run_priority,
  @output_file_name,
  @flags,
  @proxy_id,
  @proxy_name,
  @step_uid OUTPUT
END
GO

GRANT EXECUTE ON [dbo].[sp_add_jobstep_override] TO [SQLAgentOperatorRole]
GO

CREATE PROCEDURE [dbo].[sp_delete_job_override]
	@job_id					UNIQUEIDENTIFIER	= NULL, 
	@job_name				sysname				= NULL, 
	@originating_server		sysname				= NULL, 
	@delete_history			BIT					= 1,
	@delete_unused_schedule	BIT					= 1
WITH EXECUTE AS OWNER
AS
BEGIN
   EXEC dbo.sp_delete_job
      @job_id
      ,@job_name
      ,@originating_server
      ,@delete_history
      ,@delete_unused_schedule
END
GO

GRANT EXECUTE ON [dbo].[sp_delete_job_override] TO [SQLAgentOperatorRole]
GO

CREATE PROCEDURE [dbo].[sp_update_job_override]
      @job_id                       UNIQUEIDENTIFIER = NULL,
      @job_name                     sysname          = NULL,
      @new_name                     sysname          = NULL,
      @enabled                      TINYINT          = NULL,
      @description                  NVARCHAR(512)    = NULL,
      @start_step_id                INT              = NULL,
      @category_name                sysname          = NULL,
      @owner_login_name             sysname          = NULL,
      @notify_level_eventlog        INT              = NULL,
      @notify_level_email           INT              = NULL,
      @notify_level_netsend         INT              = NULL,
      @notify_level_page            INT              = NULL,
      @notify_email_operator_name   sysname          = NULL,
      @notify_netsend_operator_name sysname          = NULL,
      @notify_page_operator_name    sysname          = NULL,
      @delete_level                 INT              = NULL,
      @automatic_post               BIT              = 1
WITH EXECUTE AS OWNER
AS
BEGIN
   EXEC dbo.sp_update_job
      @job_id
      ,@job_name
      ,@new_name
      ,@enabled
      ,@description
      ,@start_step_id
      ,@category_name
      ,@owner_login_name
      ,@notify_level_eventlog
      ,@notify_level_email
      ,@notify_level_netsend
      ,@notify_level_page
      ,@notify_email_operator_name
      ,@notify_netsend_operator_name
      ,@notify_page_operator_name
      ,@delete_level
      ,@automatic_post
END
GO

GRANT EXECUTE ON [dbo].[sp_update_job_override] TO [SQLAgentOperatorRole]
GO

CREATE PROCEDURE [dbo].[sp_update_jobstep_override]
  @job_id                 UNIQUEIDENTIFIER = NULL, -- Must provide either this or job_name
  @job_name               sysname          = NULL, -- Not updatable (provided for identification purposes only)
  @step_id                INT,                     -- Not updatable (provided for identification purposes only)
  @step_name              sysname          = NULL,
  @subsystem              NVARCHAR(40)     = NULL,
  @command                NVARCHAR(MAX)    = NULL,
  @additional_parameters  NVARCHAR(MAX)    = NULL,
  @cmdexec_success_code   INT              = NULL,
  @on_success_action      TINYINT          = NULL,
  @on_success_step_id     INT              = NULL,
  @on_fail_action         TINYINT          = NULL,
  @on_fail_step_id        INT              = NULL,
  @server                 sysname          = NULL,
  @database_name          sysname          = NULL,
  @database_user_name     sysname          = NULL,
  @retry_attempts         INT              = NULL,
  @retry_interval         INT              = NULL,
  @os_run_priority        INT              = NULL,
  @output_file_name       NVARCHAR(200)    = NULL,
  @flags                  INT              = NULL,
  @proxy_id            INT          = NULL,
  @proxy_name          sysname         = NULL
  -- mutual exclusive; must specify only one of above 2 parameters to 
  -- identify the proxy. 
WITH EXECUTE AS OWNER
AS
BEGIN
	EXEC dbo.sp_update_jobstep
	  @job_id                 ,
	  @job_name               , 
	  @step_id                , 
	  @step_name              ,
	  @subsystem              ,
	  @command                ,
	  @additional_parameters  ,
	  @cmdexec_success_code   ,
	  @on_success_action      ,
	  @on_success_step_id     ,
	  @on_fail_action         ,
	  @on_fail_step_id        ,
	  @server                 ,
	  @database_name          ,
	  @database_user_name     ,
	  @retry_attempts         ,
	  @retry_interval         ,
	  @os_run_priority        ,
	  @output_file_name       ,
	  @flags                  ,
	  @proxy_id               ,
	  @proxy_name             
END
GO

GRANT EXECUTE ON [dbo].[sp_update_jobstep_override] TO [SQLAgentOperatorRole]
GO

CREATE PROCEDURE [dbo].[sp_delete_jobstep_override]
	@job_id					UNIQUEIDENTIFIER	= NULL, 
	@job_name				sysname				= NULL, 
	@step_id				INT
WITH EXECUTE AS OWNER
AS
BEGIN
   EXEC dbo.sp_delete_jobstep
      @job_id
      ,@job_name
      ,@step_id
END
GO

GRANT EXECUTE ON [dbo].[sp_delete_jobstep_override] TO [SQLAgentOperatorRole]
GO

USE [msdb]
GO

CREATE PROC [dbo].[sp_add_jobschedule_override] 
  @job_id                 UNIQUEIDENTIFIER = NULL,
  @job_name               sysname          = NULL,
  @name                   sysname,
  @enabled                TINYINT          = 1,
  @freq_type              INT              = 1,
  @freq_interval          INT              = 0,
  @freq_subday_type       INT              = 0,
  @freq_subday_interval   INT              = 0,
  @freq_relative_interval INT              = 0,
  @freq_recurrence_factor INT              = 0,
  @active_start_date      INT              = NULL,     -- sp_verify_schedule assigns a default
  @active_end_date        INT              = 99991231, -- December 31st 9999
  @active_start_time      INT              = 000000,   -- 12:00:00 am
  @active_end_time        INT              = 235959,    -- 11:59:59 pm
  @schedule_id            INT              = NULL  OUTPUT,
  @automatic_post         BIT              = 1,         -- If 1 will post notifications to all tsx servers to that run this job
  @schedule_uid           UNIQUEIDENTIFIER = NULL OUTPUT
WITH EXECUTE AS OWNER
AS
BEGIN
   EXEC [dbo].[sp_add_jobschedule]                 
		@job_id,
		@job_name,
		@name,
		@enabled,
		@freq_type,
		@freq_interval,
		@freq_subday_type,
		@freq_subday_interval,
		@freq_relative_interval,
		@freq_recurrence_factor,
		@active_start_date,
		@active_end_date,
		@active_start_time,
		@active_end_time,
		@schedule_id OUTPUT,
		@automatic_post,
		@schedule_uid OUTPUT
END
GO

GRANT EXECUTE ON [dbo].[sp_add_jobschedule_override] TO [SQLAgentOperatorRole]
GO

CREATE PROCEDURE [dbo].[sp_update_schedule_override]
(
  @schedule_id              INT             = NULL,     -- Must provide either this or schedule_name
  @name                     sysname         = NULL,     -- Must provide either this or schedule_id
  @new_name                 sysname         = NULL,
  @enabled                  TINYINT         = NULL,
  @freq_type                INT             = NULL,
  @freq_interval            INT             = NULL,
  @freq_subday_type         INT             = NULL,
  @freq_subday_interval     INT             = NULL,
  @freq_relative_interval   INT             = NULL,
  @freq_recurrence_factor   INT             = NULL,
  @active_start_date        INT             = NULL, 
  @active_end_date          INT             = NULL,
  @active_start_time        INT             = NULL,
  @active_end_time          INT             = NULL,
  @owner_login_name         sysname         = NULL,
  @automatic_post           BIT             = 1         -- If 1 will post notifications to all tsx servers to 
                                                        -- update all jobs that use this schedule
)
WITH EXECUTE AS OWNER
AS
BEGIN
	EXEC dbo.sp_update_schedule
		@schedule_id,
		@name,
		@new_name,
		@enabled,
		@freq_type,
		@freq_interval,
		@freq_subday_type,
		@freq_subday_interval,
		@freq_relative_interval,
		@freq_recurrence_factor,
		@active_start_date,
		@active_end_date,
		@active_start_time,
		@active_end_time,
		@owner_login_name,
		@automatic_post
END
GO

GRANT EXECUTE ON [dbo].[sp_update_schedule_override] TO [SQLAgentOperatorRole]
GO


print 'Creating sp_who3...'
go

USE [master]
GO
if exists(select 1 from sysobjects where name = 'sp_who3' and type = 'P')
	drop procedure sp_who3
go

CREATE procedure [dbo].[sp_who3]  --- 1995/11/03 10:16
	@dbname     sysname = NULL,	
	@loginame	sysname = NULL
as
-- Ajay - put in a dbname parameter to look for results only for the specified dbname
-- Ajay 02/18/2011 -- made changes to show active sessions only if dbname = 'active'
-- Ajay 05/11/2012 -- removed RequestId, added sql statement being run
-- Ajay 10/29/2013 -- show only those sessions where spid > 50
-- Ajay 08/15/2014 -- show the individual statement being run. Also, skip current session
set nocount on
if @dbname = 'active' select @loginame = 'active'
declare
    @retcode         int

declare
    @sidlow         varbinary(85)
   ,@sidhigh        varbinary(85)
   ,@sid1           varbinary(85)
   ,@spidlow         int
   ,@spidhigh        int

declare
    @charMaxLenLoginName      varchar(6)
   ,@charMaxLenDBName         varchar(6)
   ,@charMaxLenCPUTime        varchar(10)
   ,@charMaxLenDiskIO         varchar(10)
   ,@charMaxLenHostName       varchar(10)
   ,@charMaxLenProgramName    varchar(10)
   ,@charMaxLenLastBatch      varchar(10)
   ,@charMaxLenCommand        varchar(10)

declare
    @charsidlow              varchar(85)
   ,@charsidhigh             varchar(85)
   ,@charspidlow              varchar(11)
   ,@charspidhigh             varchar(11)

-- defaults

select @retcode         = 0      -- 0=good ,1=bad.
select @sidlow = convert(varbinary(85), (replicate(char(0), 85)))
select @sidhigh = convert(varbinary(85), (replicate(char(1), 85)))

select
    @spidlow         = 0
   ,@spidhigh        = 32767

--------------------------------------------------------------
IF (@loginame IS     NULL)  --Simple default to all LoginNames.
      GOTO LABEL_17PARM1EDITED

-- select @sid1 = suser_sid(@loginame)
select @sid1 = null
if exists(select * from sys.syslogins where loginname = @loginame)
	select @sid1 = sid from sys.syslogins where loginname = @loginame

IF (@sid1 IS NOT NULL)  --Parm is a recognized login name.
   begin
   select @sidlow  = suser_sid(@loginame)
         ,@sidhigh = suser_sid(@loginame)
   GOTO LABEL_17PARM1EDITED
   end

--------

IF (lower(@loginame collate Latin1_General_CI_AS) IN ('active'))  --Special action, not sleeping.
   begin
   select @loginame = lower(@loginame collate Latin1_General_CI_AS)
   GOTO LABEL_17PARM1EDITED
   end

--------

IF (patindex ('%[^0-9]%' , isnull(@loginame,'z')) = 0)  --Is a number.
   begin
   select
             @spidlow   = convert(int, @loginame)
            ,@spidhigh  = convert(int, @loginame)
   GOTO LABEL_17PARM1EDITED
   end

--------

raiserror(15007,-1,-1,@loginame)
select @retcode = 1
GOTO LABEL_86RETURN


LABEL_17PARM1EDITED:


--------------------  Capture consistent sysprocesses.  -------------------

select
  spid
 ,status
 ,sid
 ,hostname
 ,program_name
 ,cmd
 ,cpu
 ,physical_io
 ,blocked
 ,s.dbid
 ,convert(sysname, rtrim(loginame))
        as loginname
 ,spid as 'spid_sort'

 ,  substring( convert(varchar,last_batch,111) ,6  ,5 ) + ' '
  + substring( convert(varchar,last_batch,113) ,13 ,8 )
       as 'last_batch_char'
 ,qt.text AS 'SQLStatement'

 ,CurrentStatement =
    SUBSTRING(qt.text, ((s.stmt_start/2)+1),
        (CASE WHEN s.stmt_end = -1 THEN 2147483647
            ELSE ((s.stmt_end - s.stmt_start)/2)+1
         END
    )
)
into    #tb1_sysprocesses
from master.dbo.sysprocesses s with (nolock)
OUTER APPLY sys.dm_exec_sql_text(s.sql_handle) as qt
where db_name(s.dbid) = 
case 
	when @dbname is null then db_name(s.dbid)
	when @dbname = 'active' then db_name(s.dbid)
	else @dbname
end

if @@error <> 0
	begin
		select @retcode = @@error
		GOTO LABEL_86RETURN
	end

--------Screen out any rows?

if (@loginame in ('active'))
   delete #tb1_sysprocesses
         where   lower(status)  = 'sleeping'
         and     upper(cmd)    in (
                     'AWAITING COMMAND'
                    ,'LAZY WRITER'
                    ,'CHECKPOINT SLEEP'
                                  )

         and     blocked       = 0



--------Prepare to dynamically optimize column widths.


select
    @charsidlow     = convert(varchar(85),@sidlow)
   ,@charsidhigh    = convert(varchar(85),@sidhigh)
   ,@charspidlow     = convert(varchar,@spidlow)
   ,@charspidhigh    = convert(varchar,@spidhigh)



select
             @charMaxLenLoginName =
                  convert( varchar
                          ,isnull( max( datalength(loginname)) ,5)
                         )

            ,@charMaxLenDBName    =
                  convert( varchar
                          ,isnull( max( datalength( rtrim(convert(varchar(128),db_name(dbid))))) ,6)
                         )

            ,@charMaxLenCPUTime   =
                  convert( varchar
                          ,isnull( max( datalength( rtrim(convert(varchar(128),cpu)))) ,7)
                         )

            ,@charMaxLenDiskIO    =
                  convert( varchar
                          ,isnull( max( datalength( rtrim(convert(varchar(128),physical_io)))) ,6)
                         )

            ,@charMaxLenCommand  =
                  convert( varchar
                          ,isnull( max( datalength( rtrim(convert(varchar(128),cmd)))) ,7)
                         )

            ,@charMaxLenHostName  =
                  convert( varchar
                          ,isnull( max( datalength( rtrim(convert(varchar(128),hostname)))) ,8)
                         )

            ,@charMaxLenProgramName =
                  convert( varchar
                          ,isnull( max( datalength( rtrim(convert(varchar(128),program_name)))) ,11)
                         )

            ,@charMaxLenLastBatch =
                  convert( varchar
                          ,isnull( max( datalength( rtrim(convert(varchar(128),last_batch_char)))) ,9)
                         )
      from
             #tb1_sysprocesses
      where
             spid >= @spidlow
      and    spid <= @spidhigh



--------Output the report.


EXEC(
'
SET nocount off

SELECT
             SPID          = convert(char(5),spid)

            ,Status        =
                  CASE lower(status)
                     When ''sleeping'' Then lower(status)
                     Else                   upper(status)
                  END

            ,Login         = substring(loginname,1,' + @charMaxLenLoginName + ')

            ,HostName      =
                  CASE hostname
                     When Null  Then ''  .''
                     When '' '' Then ''  .''
                     Else    substring(hostname,1,' + @charMaxLenHostName + ')
                  END

            ,BlkBy         =
                  CASE               isnull(convert(char(5),blocked),''0'')
                     When ''0'' Then ''  .''
                     Else            isnull(convert(char(5),blocked),''0'')
                  END

            ,DBName        = substring(case when dbid = 0 then null when dbid <> 0 then db_name(dbid) end,1,' + @charMaxLenDBName + ')
            ,Command       = substring(cmd,1,' + @charMaxLenCommand + ')

            ,CPUTime       = substring(convert(varchar,cpu),1,' + @charMaxLenCPUTime + ')
            ,DiskIO        = substring(convert(varchar,physical_io),1,' + @charMaxLenDiskIO + ')

            ,LastBatch     = substring(last_batch_char,1,' + @charMaxLenLastBatch + ')

            ,ProgramName   = substring(program_name,1,' + @charMaxLenProgramName + ')
            ,SPID          = convert(char(5),spid)  --Handy extra for right-scrolling users.
            ,SQLStatement  = SQLStatement
            ,CurrentStatement = CurrentStatement
      from
             #tb1_sysprocesses  --Usually DB qualification is needed in exec().
      where
			 dbid <> 0
	  and    spid >= ' + @charspidlow  + '
      and    spid <= ' + @charspidhigh + '
      and	 spid > 50
      and	 spid <> @@spid
      order by spid_sort

      -- (Seems always auto sorted.)   order by spid_sort

SET nocount on
'
)


LABEL_86RETURN:


if (object_id('tempdb..#tb1_sysprocesses') is not null)
            drop table #tb1_sysprocesses

return @retcode -- sp_who3

GO


print 'Creating admin logins...'
go
if not exists (select 1 from syslogins where name = 'dbmonitor')
Begin 
	create login [dbmonitor] with password = 0x0100b825a971013f9cdfaaf882ca93f85eccc520ffd5f99c7920 hashed, sid = 0xa644373306a3e842bf9abc785148f9d4, check_policy = ON, check_expiration = OFF, default_database = master, default_language = us_english
End
if not exists (select 1 FROM syslogins where name = 'dbremote')
Begin
	create login [dbremote] with password = 0x0100660c539377fabfd98817847b571a13083ac24505b85b6d5b hashed, sid = 0x3d970c6529bb8441aae63c2c5ee96ba4, check_policy = ON, check_expiration = OFF, default_database = master, default_language = us_english
End
if not exists (select 1 FROM syslogins where name = 'wikireader')
Begin
	create login [wikireader] with password = 0x0100b3626e2417071faa16754a575d534f6942ea46f7994711f2 hashed, sid = 0xfe47fca107ce8d489c1c629330bdeeb7, check_policy = ON, check_expiration = OFF, default_database = master, default_language = us_english
End
if not exists (select 1 from syslogins where name = 'OpsView')
Begin 
	create login [OpsView] with password = 0x010072bda9f8f8d4cd4e1b37dad2c3c1c93448abea7dd1f1e4ab hashed, sid = 0xcc1d6ada77ec3a458ec0f9f12be79c64, check_policy = ON, check_expiration = OFF, default_database = master, default_language = us_english
End
if not exists (select 1 from syslogins where name = 'WVRGROUP\DBOPS')
Begin 
	create login [WVRGROUP\DBOPS] from windows with default_database = master, default_language = us_english
End
GO
if not exists (select 1 from syslogins where name = 'WVRGROUP\DBProdAccess')
Begin
	create login [WVRGROUP\DBProdAccess] from windows with default_database = master, default_language = us_english
End
Go
EXEC sys.sp_addsrvrolemember @loginame = N'dbmonitor', @rolename = N'sysadmin'
GO
EXEC sys.sp_addsrvrolemember @loginame = N'dbremote', @rolename = N'sysadmin'
GO
EXEC sys.sp_addsrvrolemember @loginame = N'WVRGROUP\DBOPS', @rolename = N'sysadmin'
GO

ALTER LOGIN [sa] WITH DEFAULT_DATABASE=[master], CHECK_EXPIRATION=OFF, CHECK_POLICY=OFF
GO
ALTER LOGIN [sa] WITH PASSWORD = 0x0100258e1213d7012dcf8c41a754d5f89d0b01e3ec41cc994b25 hashed
GO
ALTER LOGIN [sa] WITH DEFAULT_DATABASE=[master], CHECK_EXPIRATION=OFF, CHECK_POLICY=ON
GO
ALTER LOGIN sa DISABLE
GO

if not exists (select 1 from syslogins where name = 'HOMEAWAY0\DBOPS')
Begin 
	create login [HOMEAWAY0\DBOPS] from windows with default_database = master, default_language = us_english
End
GO
EXEC sys.sp_addsrvrolemember @loginame = N'HOMEAWAY0\DBOPS', @rolename = N'sysadmin'
GO

if not exists (select 1 from syslogins where name = 'HOMEAWAY0\prd-sqlmonitor-svc')
Begin 
	create login [HOMEAWAY0\prd-sqlmonitor-svc] from windows with default_database = master, default_language = us_english
End
GO
EXEC sys.sp_addsrvrolemember @loginame = N'HOMEAWAY0\prd-sqlmonitor-svc', @rolename = N'sysadmin'
GO

if not exists (select 1 from syslogins where name = 'HOMEAWAY0\cicd')
Begin 
	create login [HOMEAWAY0\cicd] from windows with default_database = master, default_language = us_english
End
GO
EXEC sys.sp_addsrvrolemember @loginame = N'HOMEAWAY0\cicd', @rolename = N'sysadmin'
GO

DECLARE @cmd VARCHAR(100)
IF @@SERVICENAME = 'MSSQLSERVER'
BEGIN
	SELECT @cmd = 'DROP LOGIN [NT SERVICE\MSSQLSERVER]'
	EXEC(@cmd)
	SELECT @cmd = 'DROP LOGIN [NT SERVICE\SQLSERVERAGENT]'
	EXEC(@cmd)
END
ELSE
BEGIN
	SELECT @cmd = 'DROP LOGIN [NT SERVICE\MSSQL$'+@@SERVICENAME+']'
	EXEC(@cmd)
	SELECT @cmd = 'DROP LOGIN [NT SERVICE\SQLAgent$'+@@SERVICENAME+']'
	EXEC(@cmd)
END
GO

if exists (select 1 from syslogins where name = 'WVRGROUP\DBA')
begin
	DROP LOGIN [WVRGROUP\DBA]
end
GO

use master
go
GRANT VIEW ANY DEFINITION TO wikireader
GRANT VIEW SERVER STATE TO wikireader
GO

USE model	-- for future databases
GO
CREATE USER wikireader FOR LOGIN wikireader
GO

USE dbadmin
GO
IF NOT EXISTS(SELECT 1 FROM sys.database_principals WHERE name = 'wikireader' AND type = 'S')
BEGIN
	CREATE USER wikireader FOR LOGIN wikireader
	EXEC sp_addrolemember N'db_datareader', N'wikireader'
END
GO


print 'Creating the SQL job - Nightly Maintenance...'
go

USE [msdb]
GO

BEGIN TRANSACTION
DECLARE @ReturnCode INT
SELECT @ReturnCode = 0
IF NOT EXISTS (SELECT name FROM msdb.dbo.syscategories WHERE name=N'[Uncategorized (Local)]' AND category_class=1)
BEGIN
EXEC @ReturnCode = msdb.dbo.sp_add_category @class=N'JOB', @type=N'LOCAL', @name=N'[Uncategorized (Local)]'
IF (@@ERROR <> 0 OR @ReturnCode <> 0) GOTO QuitWithRollback

END

DECLARE @jobId BINARY(16)
EXEC @ReturnCode =  msdb.dbo.sp_add_job @job_name=N'Nightly Server Maintenance', 
		@enabled=1, 
		@notify_level_eventlog=2, 
		@notify_level_email=0, 
		@notify_level_netsend=0, 
		@notify_level_page=0, 
		@delete_level=0, 
		@description=N'No description available.', 
		@category_name=N'[Uncategorized (Local)]', 
		@owner_login_name=N'sa', @job_id = @jobId OUTPUT
IF (@@ERROR <> 0 OR @ReturnCode <> 0) GOTO QuitWithRollback
EXEC @ReturnCode = msdb.dbo.sp_add_jobstep @job_id=@jobId, @step_name=N'Recycle Errorlog', 
		@step_id=1, 
		@cmdexec_success_code=0, 
		@on_success_action=3, 
		@on_success_step_id=0, 
		@on_fail_action=2, 
		@on_fail_step_id=0, 
		@retry_attempts=0, 
		@retry_interval=1, 
		@os_run_priority=0, @subsystem=N'TSQL', 
		@command=N'EXEC sp_cycle_errorlog', 
		@database_name=N'master', 
		@flags=0
IF (@@ERROR <> 0 OR @ReturnCode <> 0) GOTO QuitWithRollback
EXEC @ReturnCode = msdb.dbo.sp_add_jobstep @job_id=@jobId, @step_name=N'change job owners to sqlservices', 
		@step_id=2, 
		@cmdexec_success_code=0, 
		@on_success_action=3, 
		@on_success_step_id=0, 
		@on_fail_action=2, 
		@on_fail_step_id=0, 
		@retry_attempts=0, 
		@retry_interval=0, 
		@os_run_priority=0, @subsystem=N'TSQL', 
		@command=N'exec dbadmin.dbo.pr_ChangeJobOwners', 
		@database_name=N'master', 
		@output_file_name=N'D:\MSSQL\Logs\NightlyServerMaintenance.txt', 
		@flags=0
IF (@@ERROR <> 0 OR @ReturnCode <> 0) GOTO QuitWithRollback
EXEC @ReturnCode = msdb.dbo.sp_add_jobstep @job_id=@jobId, @step_name=N'change DB owners to sqlservices', 
		@step_id=3, 
		@cmdexec_success_code=0, 
		@on_success_action=1, 
		@on_success_step_id=0, 
		@on_fail_action=2, 
		@on_fail_step_id=0, 
		@retry_attempts=0, 
		@retry_interval=0, 
		@os_run_priority=0, @subsystem=N'TSQL', 
		@command=N'exec dbadmin.dbo.pr_ChangeDBOwners', 
		@database_name=N'master', 
		@output_file_name=N'D:\MSSQL\Logs\NightlyServerMaintenance.txt', 
		@flags=2
IF (@@ERROR <> 0 OR @ReturnCode <> 0) GOTO QuitWithRollback
EXEC @ReturnCode = msdb.dbo.sp_update_job @job_id = @jobId, @start_step_id = 1
IF (@@ERROR <> 0 OR @ReturnCode <> 0) GOTO QuitWithRollback
EXEC @ReturnCode = msdb.dbo.sp_add_jobschedule @job_id=@jobId, @name=N'Sch1', 
		@enabled=1, 
		@freq_type=4, 
		@freq_interval=1, 
		@freq_subday_type=1, 
		@freq_subday_interval=0, 
		@freq_relative_interval=0, 
		@freq_recurrence_factor=1, 
		@active_start_date=20100825, 
		@active_end_date=99991231, 
		@active_start_time=30000, 
		@active_end_time=235959
IF (@@ERROR <> 0 OR @ReturnCode <> 0) GOTO QuitWithRollback
EXEC @ReturnCode = msdb.dbo.sp_add_jobserver @job_id = @jobId, @server_name = N'(local)'
IF (@@ERROR <> 0 OR @ReturnCode <> 0) GOTO QuitWithRollback
COMMIT TRANSACTION
GOTO EndSave
QuitWithRollback:
    IF (@@TRANCOUNT > 0) ROLLBACK TRANSACTION
EndSave:

GO

print 'Creating the SQL job - Capture Schema Changes...'
go

USE [msdb]
GO

BEGIN TRANSACTION
DECLARE @ReturnCode INT
SELECT @ReturnCode = 0
IF NOT EXISTS (SELECT name FROM msdb.dbo.syscategories WHERE name=N'[Uncategorized (Local)]' AND category_class=1)
BEGIN
EXEC @ReturnCode = msdb.dbo.sp_add_category @class=N'JOB', @type=N'LOCAL', @name=N'[Uncategorized (Local)]'
IF (@@ERROR <> 0 OR @ReturnCode <> 0) GOTO QuitWithRollback

END

DECLARE @jobId BINARY(16)
EXEC @ReturnCode =  msdb.dbo.sp_add_job @job_name=N'Capture Schema Changes', 
		@enabled=1, 
		@notify_level_eventlog=0, 
		@notify_level_email=0, 
		@notify_level_netsend=0, 
		@notify_level_page=0, 
		@delete_level=0, 
		@description=N'No description available.', 
		@category_name=N'[Uncategorized (Local)]', 
		@owner_login_name=N'sa', @job_id = @jobId OUTPUT
IF (@@ERROR <> 0 OR @ReturnCode <> 0) GOTO QuitWithRollback
EXEC @ReturnCode = msdb.dbo.sp_add_jobstep @job_id=@jobId, @step_name=N'Schema Changes', 
		@step_id=1, 
		@cmdexec_success_code=0, 
		@on_success_action=1, 
		@on_success_step_id=0, 
		@on_fail_action=2, 
		@on_fail_step_id=0, 
		@retry_attempts=0, 
		@retry_interval=0, 
		@os_run_priority=0, @subsystem=N'TSQL', 
		@command=N'exec dbadmin.dbo.pr_CaptureSchemaChanges', 
		@database_name=N'master', 
		@flags=0
IF (@@ERROR <> 0 OR @ReturnCode <> 0) GOTO QuitWithRollback
EXEC @ReturnCode = msdb.dbo.sp_update_job @job_id = @jobId, @start_step_id = 1
IF (@@ERROR <> 0 OR @ReturnCode <> 0) GOTO QuitWithRollback
EXEC @ReturnCode = msdb.dbo.sp_add_jobschedule @job_id=@jobId, @name=N'Daily', 
		@enabled=1, 
		@freq_type=4, 
		@freq_interval=1, 
		@freq_subday_type=4, 
		@freq_subday_interval=2, 
		@freq_relative_interval=0, 
		@freq_recurrence_factor=0, 
		@active_start_date=20131121, 
		@active_end_date=99991231, 
		@active_start_time=0, 
		@active_end_time=235959
IF (@@ERROR <> 0 OR @ReturnCode <> 0) GOTO QuitWithRollback
EXEC @ReturnCode = msdb.dbo.sp_add_jobserver @job_id = @jobId, @server_name = N'(local)'
IF (@@ERROR <> 0 OR @ReturnCode <> 0) GOTO QuitWithRollback
COMMIT TRANSACTION
GOTO EndSave
QuitWithRollback:
    IF (@@TRANCOUNT > 0) ROLLBACK TRANSACTION
EndSave:

GO

print 'Creating the SQL job - Capture LUN Information...'
go

USE [msdb]
GO

BEGIN TRANSACTION
DECLARE @ReturnCode INT
SELECT @ReturnCode = 0
IF NOT EXISTS (SELECT name FROM msdb.dbo.syscategories WHERE name=N'[Uncategorized (Local)]' AND category_class=1)
BEGIN
EXEC @ReturnCode = msdb.dbo.sp_add_category @class=N'JOB', @type=N'LOCAL', @name=N'[Uncategorized (Local)]'
IF (@@ERROR <> 0 OR @ReturnCode <> 0) GOTO QuitWithRollback

END

DECLARE @jobId BINARY(16)
EXEC @ReturnCode =  msdb.dbo.sp_add_job @job_name=N'Capture LUN Information', 
		@enabled=1, 
		@notify_level_eventlog=0, 
		@notify_level_email=0, 
		@notify_level_netsend=0, 
		@notify_level_page=0, 
		@delete_level=0, 
		@description=N'No description available.', 
		@category_name=N'[Uncategorized (Local)]', 
		@owner_login_name=N'sa', @job_id = @jobId OUTPUT
IF (@@ERROR <> 0 OR @ReturnCode <> 0) GOTO QuitWithRollback
EXEC @ReturnCode = msdb.dbo.sp_add_jobstep @job_id=@jobId, @step_name=N'LUN information', 
		@step_id=1, 
		@cmdexec_success_code=0, 
		@on_success_action=1, 
		@on_success_step_id=0, 
		@on_fail_action=2, 
		@on_fail_step_id=0, 
		@retry_attempts=0, 
		@retry_interval=0, 
		@os_run_priority=0, @subsystem=N'TSQL', 
		@command=N'exec dbadmin.dbo.pr_LUNInfo', 
		@database_name=N'master', 
		@flags=0
IF (@@ERROR <> 0 OR @ReturnCode <> 0) GOTO QuitWithRollback
EXEC @ReturnCode = msdb.dbo.sp_update_job @job_id = @jobId, @start_step_id = 1
IF (@@ERROR <> 0 OR @ReturnCode <> 0) GOTO QuitWithRollback
EXEC @ReturnCode = msdb.dbo.sp_add_jobschedule @job_id=@jobId, @name=N'Daily', 
		@enabled=1, 
		@freq_type=4, 
		@freq_interval=1, 
		@freq_subday_type=8, 
		@freq_subday_interval=1, 
		@freq_relative_interval=0, 
		@freq_recurrence_factor=0, 
		@active_start_date=20150706, 
		@active_end_date=99991231, 
		@active_start_time=0, 
		@active_end_time=235959
IF (@@ERROR <> 0 OR @ReturnCode <> 0) GOTO QuitWithRollback
EXEC @ReturnCode = msdb.dbo.sp_add_jobserver @job_id = @jobId, @server_name = N'(local)'
IF (@@ERROR <> 0 OR @ReturnCode <> 0) GOTO QuitWithRollback
COMMIT TRANSACTION
GOTO EndSave
QuitWithRollback:
    IF (@@TRANCOUNT > 0) ROLLBACK TRANSACTION
EndSave:

GO


use master
go

print 'Reconfiguring model database file autogrowth settings...'
go
ALTER DATABASE model MODIFY FILE (NAME = N'modeldev', FILEGROWTH = 1GB)
GO
ALTER DATABASE model MODIFY FILE (NAME = N'modellog', FILEGROWTH = 1GB)
GO

print 'Reconfiguring TEMPDB - moving/adding more files...'
go
print 'Current files and location...'
go
SELECT name, physical_name, type_desc
FROM sys.master_files
WHERE database_id = DB_ID('tempdb');
GO

IF CAST(SERVERPROPERTY('ProductVersion') AS VARCHAR) < '13' -- thru SQL SERVER 2014
BEGIN
	-- Move current files
	ALTER DATABASE tempdb MODIFY FILE (NAME = tempdev, FILENAME = 'T:\MSSQL\Data\tempdb.mdf');
	ALTER DATABASE tempdb MODIFY FILE (NAME = templog, FILENAME = 'T:\MSSQL\Logs\templog.ldf');

	-- Add more files
	ALTER DATABASE tempdb add FILE (NAME = tempdev2, FILENAME = 'T:\MSSQL\Data\tempdb2.ndf');
	ALTER DATABASE tempdb add FILE (NAME = tempdev3, FILENAME = 'T:\MSSQL\Data\tempdb3.ndf');
	ALTER DATABASE tempdb add FILE (NAME = tempdev4, FILENAME = 'T:\MSSQL\Data\tempdb4.ndf');
	ALTER DATABASE tempdb add FILE (NAME = tempdev5, FILENAME = 'T:\MSSQL\Data\tempdb5.ndf');
	ALTER DATABASE tempdb add FILE (NAME = tempdev6, FILENAME = 'T:\MSSQL\Data\tempdb6.ndf');
	ALTER DATABASE tempdb add FILE (NAME = tempdev7, FILENAME = 'T:\MSSQL\Data\tempdb7.ndf');
	ALTER DATABASE tempdb add FILE (NAME = tempdev8, FILENAME = 'T:\MSSQL\Data\tempdb8.ndf');

	-- Change tempdb file settings
	alter database tempdb modify file (NAME = tempdev,  size = 1GB, FILEGROWTH = 1GB, MAXSIZE = 10GB);
	alter database tempdb modify file (NAME = tempdev2, size = 1GB, FILEGROWTH = 1GB, MAXSIZE = 10GB);
	alter database tempdb modify file (NAME = tempdev3, size = 1GB, FILEGROWTH = 1GB, MAXSIZE = 10GB);
	alter database tempdb modify file (NAME = tempdev4, size = 1GB, FILEGROWTH = 1GB, MAXSIZE = 10GB);
	alter database tempdb modify file (NAME = tempdev5, size = 1GB, FILEGROWTH = 1GB, MAXSIZE = 10GB);
	alter database tempdb modify file (NAME = tempdev6, size = 1GB, FILEGROWTH = 1GB, MAXSIZE = 10GB);
	alter database tempdb modify file (NAME = tempdev7, size = 1GB, FILEGROWTH = 1GB, MAXSIZE = 10GB);
	alter database tempdb modify file (NAME = tempdev8, size = 1GB, FILEGROWTH = 1GB, MAXSIZE = 10GB);
	alter database tempdb modify file (NAME = templog,  size = 1GB, FILEGROWTH = 1GB, MAXSIZE = 10GB);

	print 'RESTART SQL SERVICE and drop the tempdb files (tempdb.mdf, templog.ldf) from """""""OLD LOCATION""""""" ...'
	print 'RESTART SQL SERVICE and drop the tempdb files (tempdb.mdf, templog.ldf) from """""""OLD LOCATION""""""" ...'
	select 'RESTART SQL SERVICE and drop the tempdb files (tempdb.mdf, templog.ldf) from """""""OLD LOCATION""""""" ...'
	select 'RESTART SQL SERVICE and drop the tempdb files (tempdb.mdf, templog.ldf) from """""""OLD LOCATION""""""" ...'
	select 'RESTART SQL SERVICE and drop the tempdb files (tempdb.mdf, templog.ldf) from """""""OLD LOCATION""""""" ...'
END
GO


-- Check TCP Chimney setting
set nocount on
declare @tbl table(rslt varchar(200))
declare @cmd varchar(100)
insert @tbl exec master..xp_cmdshell 'netsh int tcp show global'
select @cmd = rslt from @tbl where rslt like 'Chimney Offload State%'	-- status can be automatic, disabled, enabled
select @cmd
if (select CHARINDEX('enabled', @cmd, 1)) > 0
begin
	print 'TCP CHIMNEY ENABLED!!!!!!!!! ASK THE OPS GUYS TO DISABLE IT......'
	print 'TCP CHIMNEY ENABLED!!!!!!!!! ASK THE OPS GUYS TO DISABLE IT......'
	select 'TCP CHIMNEY ENABLED!!!!!!!!! ASK THE OPS GUYS TO DISABLE IT......'
	select 'TCP CHIMNEY ENABLED!!!!!!!!! ASK THE OPS GUYS TO DISABLE IT......'
	select 'TCP CHIMNEY ENABLED!!!!!!!!! ASK THE OPS GUYS TO DISABLE IT......'
end
GO

-- Check for HOMEAWAY0\sqlservices, EUTRIPS\sqlservices, wvrgroup\sqlservices as part of localgroup administrators
-- Add the user to the administrators group if needed
set nocount on
DECLARE @tbl table(rslt varchar(200))
DECLARE @cmd varchar(100)
DECLARE @Domain varchar(100), @key varchar(100)
DECLARE @profile_name VARCHAR(50), @account_name VARCHAR(50), @description VARCHAR(50)
DECLARE @display_name VARCHAR(50), @mailserver_name VARCHAR(50), @user VARCHAR(50)
SET @key = 'SYSTEM\ControlSet001\Services\Tcpip\Parameters\'
SET @user = SUSER_NAME()
EXEC master..xp_regread @rootkey='HKEY_LOCAL_MACHINE', @key=@key,@value_name='Domain',@value=@Domain OUTPUT 
insert @tbl exec master..xp_cmdshell 'net localgroup administrators'
delete @tbl where rslt is NULL
SELECT 'Server Name: '+@@servername + ', Domain Name: '+@Domain 
if CHARINDEX('eutrips', @Domain, 1) > 0 
BEGIN
	if not exists (select 1 from @tbl where rslt = 'EUTRIPS\sqlservices') 
		exec master..xp_cmdshell 'net localgroup administrators EUTRIPS\sqlservices /add', no_output
	if not exists (select 1 from @tbl where rslt = 'HOMEAWAY0\sqlservices') 
		exec master..xp_cmdshell 'net localgroup administrators HOMEAWAY0\sqlservices /add', no_output
END
ELSE if CHARINDEX('homeaway', @Domain, 1) > 0 
BEGIN
	if not exists (select 1 from @tbl where rslt = 'HOMEAWAY0\sqlservices') 
		exec master..xp_cmdshell 'net localgroup administrators HOMEAWAY0\sqlservices /add', no_output
END
ELSE if CHARINDEX('wvrgroup', @Domain, 1) > 0 
BEGIN
	if not exists (select 1 from @tbl where rslt = 'wvrgroup\sqlservices') 
		exec master..xp_cmdshell 'net localgroup administrators wvrgroup\sqlservices /add', no_output
	if not exists (select 1 from @tbl where rslt = 'HOMEAWAY0\sqlservices') 
		exec master..xp_cmdshell 'net localgroup administrators HOMEAWAY0\sqlservices /add', no_output
END
ELSE if CHARINDEX('hahosting.local', @Domain, 1) > 0 
BEGIN
	if not exists (select 1 from @tbl where rslt = 'HAHOSTING\xg-dev-sqlservices') 
		exec master..xp_cmdshell 'net localgroup administrators HAHOSTING\xg-dev-sqlservices /add', no_output
	if not exists (select 1 from @tbl where rslt = 'HOMEAWAY0\sqlservices') 
		exec master..xp_cmdshell 'net localgroup administrators HOMEAWAY0\sqlservices /add', no_output
END
if not exists (select 1 from @tbl where rslt = 'WVRGROUP\dbops') 
begin
	exec master..xp_cmdshell 'net localgroup administrators WVRGROUP\dbops /add', no_output
end
if not exists (select 1 from @tbl where rslt = 'HOMEAWAY0\dbops') 
begin
	exec master..xp_cmdshell 'net localgroup administrators HOMEAWAY0\dbops /add', no_output
end
if not exists (select 1 from @tbl where rslt = 'HOMEAWAY0\prd-sqlmonitor-svc') 
begin
	exec master..xp_cmdshell 'net localgroup administrators HOMEAWAY0\prd-sqlmonitor-svc /add', no_output
end
GO

print 'ALL DONE.......'
go

