# ============================================================
# Attendance Batch - Windows PowerShell Version
# Ported from Linux Bash script (same logic, TXT files)
# ============================================================

# -------------------------------
# Configuration
# -------------------------------

$WatchDir      = "D:\testing"
$ProcessedDir  = "D:\testing\processed"
$LogDir        = "D:\testing\logs"

$DBUser        = $env:ATTENDANCE_DB_USER
$DBPassword    = $env:ATTENDANCE_DB_PASSWORD   # set this environment variable; never hardcode the password
$DBService     = "orclpdb"

# -------------------------------
# Prepare
# -------------------------------

$DateTag    = Get-Date -Format "yyyyMMdd_HHmmss"
$ScriptName = Split-Path -Leaf $PSCommandPath
$LogFile    = Join-Path $LogDir "batch_$DateTag.log"

# -------------------------------
# Create directories
# -------------------------------

foreach($Folder in @($WatchDir, $ProcessedDir, $LogDir))
{
    if(!(Test-Path $Folder))
    {
        New-Item -ItemType Directory -Path $Folder -Force | Out-Null
    }
}

# -------------------------------
# Helper: Logging
# -------------------------------

function Write-Log
{
    param([string]$Message)

    $Time = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    "$Time - $Message" | Out-File -Append -Encoding UTF8 -FilePath $LogFile
}

# -------------------------------
# Helper: Run SQL
# -------------------------------

function Invoke-Sql
{
    param([string]$SqlBody)

    $TempSQL = Join-Path $env:TEMP ("attendance_{0}.sql" -f ([guid]::NewGuid().ToString("N")))

    try
    {
        $SqlBody | Set-Content -Path $TempSQL -Encoding ASCII -Force

        $Result = sqlplus -S "$DBUser/$DBPassword@$DBService" "@$TempSQL" 2>&1
        return ($Result | Out-String)
    }
    finally
    {
        if(Test-Path $TempSQL)
        {
            Remove-Item $TempSQL -Force -ErrorAction SilentlyContinue
        }
    }
}

# -------------------------------
# Start
# -------------------------------

Write-Log "========================================="
Write-Log "Starting $ScriptName"
Write-Log "========================================="
Write-Log "Time: $DateTag"
Write-Log "Watch directory: $WatchDir"

# -------------------------------
# Check for TXT files
# -------------------------------

$TxtFiles = @(Get-ChildItem $WatchDir -Filter *.txt -File -ErrorAction SilentlyContinue)

if($TxtFiles.Count -eq 0)
{
    Write-Log "No TXT files found"
    Write-Log "========================================="
    exit 0
}

Write-Log "Found $($TxtFiles.Count) TXT file(s)"

# -------------------------------
# Process each file
# -------------------------------

foreach($File in $TxtFiles)
{
    $FileName = $File.Name
    $FileSize = $File.Length

    Write-Log "-----------------------------------------"
    Write-Log "Processing file: $FileName"
    Write-Log "Size: $FileSize bytes"

    # --- SQL ---
    $SQL = @"
SET SERVEROUTPUT ON
SET HEADING OFF
SET FEEDBACK OFF
SET PAGESIZE 0

BEGIN
    INSERT INTO attend_pending_files (file_name, status)
    VALUES ('$FileName', 'PENDING');
    COMMIT;
    DBMS_OUTPUT.PUT_LINE('SUCCESS');
EXCEPTION
    WHEN DUP_VAL_ON_INDEX THEN
        UPDATE attend_pending_files
        SET status = 'PENDING',
            added_date = SYSDATE,
            error_message = NULL
        WHERE file_name = '$FileName';
        COMMIT;
        DBMS_OUTPUT.PUT_LINE('UPDATED');
    WHEN OTHERS THEN
        DBMS_OUTPUT.PUT_LINE('ERROR: ' || SQLERRM);
        ROLLBACK;
END;
/

EXIT;
"@

    $SqlResult = Invoke-Sql -SqlBody $SQL

    Write-Log "SQL Result: $SqlResult"

    # --- Check result ---
    if($SqlResult -match "SUCCESS|UPDATED")
    {
        Write-Log "File added to pending_files table"

        # Move file to processed directory
        $Dest = Join-Path $ProcessedDir $FileName

        try
        {
            Move-Item -Path $File.FullName -Destination $Dest -Force
            Write-Log "File moved to: $ProcessedDir"
        }
        catch
        {
            Write-Log "Failed to move file: $($_.Exception.Message)"
        }
    }
    else
    {
        Write-Log "Failed to add file: $SqlResult"
    }
}

# -------------------------------
# Clean up old logs (older than 30 days)
# -------------------------------
# Get-ChildItem $LogDir -Filter "batch_*.log" -File |
#     Where-Object { $_.LastWriteTime -lt (Get-Date).AddDays(-30) } |
#     Remove-Item -Force

Write-Log "Processing completed"
