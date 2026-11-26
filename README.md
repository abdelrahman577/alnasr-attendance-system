# Al-Nasr Attendance System

An Oracle PL/SQL attendance and payroll-preparation system built from scratch for Al-Nasr, a company that had no HR system at all. It reads raw fingerprint punches, turns them into clean daily attendance records, detects absences, and leaves payroll with almost nothing to do by hand.

## The problem

1. **Payroll took a full month of manual work.** Punches were gathered and checked by hand, so salaries were late and error-prone.
2. **The new fingerprint device could not be integrated.** It is a very recent model with no database link, no ORDS and no API. Nothing could pull data from it, and nothing could push data to Oracle.

## The solution

The system does not try to connect to the device. It routes around it with plain text files:

1. The device exports its punch log as `.txt` files.
2. A small **watcher script** notices new files and registers them in a queue table.
3. A **PL/SQL ingestion package** (`ATTEND_PKG`) reads each queued file, parses it, cleans it and loads the punches into a staging table.
4. The **attendance engine** (`attend_eng_pkg`) resolves each employee's shift (including night shifts and rotating *wardiya* shifts), applies a day lock, and writes one row per employee per day.
5. The **absence manager** (`EMPLOYEE_ABSENCE_MANAGER`) finds who did not show up and applies excuses (vacation, mission, permission, and so on).
6. Payroll reads the daily results.
7. **Oracle scheduler jobs** run the whole chain with no manual steps.

Result: payroll preparation went from a full month of manual work to a near-automatic process, and a device with no integration options feeds the database reliably.

### Data flow

```
 Fingerprint device
        |  exports punch log
        v
   *.txt files  (watch folder)
        |
        v
 Watcher script (attendance.sh / attendance.ps1)
        |  INSERT file name, status = PENDING
        v
 ATT_PENDING_FILES  (queue)
        |
        v
 ATTEND_PKG.PROCESS_ALL_FILES
   parse 5 formats -> de-duplicate -> validate employee
        |
        +--> ATT_PARSE_ERRORS   (bad lines, unknown employees)
        +--> ATT_FILE_LOG       (files already imported)
        v
 ATT_ATTENDANCE_STAGING  (clean punches)
        |
        v
 attend_eng_pkg.run_daily_attendance
   lock day -> load punches -> resolve shifts (day / night / wardiya)
   -> first in / last out -> work minutes, late, early out, overtime hours
        |
        v
 ATT_EMP_ATTEND_DAILY  (one row per employee per day)
        |
        v
 EMPLOYEE_ABSENCE_MANAGER
   skip weekends and holidays -> detect absences -> apply excuses
        |
        v
 Payroll
```

## Components

### 1. Watcher script (OS side)

The production version runs on Linux at the company. `attendance.ps1` is a PowerShell port used for testing, with the same logic.

- Scans a watch folder for `*.txt` files.
- For each file, runs `sqlplus` and inserts the file name into `ATT_PENDING_FILES` with status `PENDING`.
- If the file name is already in the queue, the row is reset to `PENDING`, so a re-dropped file is processed again.
- Moves the file to a `processed` folder only after the database confirms the insert. If the insert fails, the file stays and is retried on the next run.
- Writes a dated log file for every run.

### 2. Ingestion: `ATTEND_PKG`

| Object | Purpose |
|---|---|
| `PROCESS_ALL_FILES` | Entry point for the scheduler. Takes pending files (one per run), calls the parser and the importer, then marks the file `PROCESSED` or `ERROR`. |
| `PROCESS_FILES` | Opens each file from the `MYDIR` directory with `UTL_FILE` and parses every line. |
| `IMPORT_FILES` | Removes double punches, sorts, checks that the employee exists in `EMP_MASTER`, skips punches already staged, then bulk-inserts with `FORALL`. |
| `PARSE_DATE`, `PARSE_TIME` | Tolerant converters for several date and time formats, including 12-hour AM/PM. |
| `GET_NAME`, `LOG_FILE` | Idempotency guard: a file recorded in `ATT_FILE_LOG` is never imported twice. |
| `REMOVE_DUPLICATE_PUNCHES` | Drops repeat punches by the same employee less than 10 minutes apart. |

The parser accepts five export formats, so one importer handles whatever the device or its export tool produces:

1. CSV: `3480,09/08/2026,08:05:06`
2. Tab or space separated, slash dates: `3480    09/08/2026    08:05:06`
3. Tab or space separated, dash dates: `3942    21-07-2026    07:31:41`
4. Concatenated with no separators: employee ID, date and time run together
5. Legacy format with AM/PM

Lines that cannot be parsed go to `ATT_PARSE_ERRORS` and do not stop the run.

Main tables: `ATT_PENDING_FILES`, `ATT_FILE_LOG`, `ATT_PARSE_ERRORS`, `ATT_ATTENDANCE_STAGING`.

### 3. Attendance engine: `attend_eng_pkg`

`run_daily_attendance(p_work_date)` runs these steps in order:

1. `lock_day`: records the day in the day-lock table so a closed day is not recomputed by accident.
2. `load_raw_attendance`: loads that day's punches from staging.
3. `resolve_shift_for_emp`: decides each employee's shift, using shift definitions and the wardiya rotation.
4. `insert_daily_attendance`: creates the daily rows.
5. `last_out_engine`: finds the exit punch, including night shifts that end the next morning.
6. `update_work_minutes`: calculates worked time.
7. `calculate_additional_metrics`: late minutes, early-out minutes, early-in, night-work time and overtime hours.
8. `update_processed_flags`: marks processed rows.
9. `sync_with_absence_system`: hands the day over to the absence manager.
10. `mark_processed_raw`: flags the staged punches as processed.

Every step writes to a log table, and a fatal error is logged and re-raised.

Main tables: `ATT_EMP_ATTEND_DAILY` (the daily result, one row per employee per day), `ATT_EMP_SHIFT` (shift definitions), the wardiya tables (rotating shift assignment, transfers and rotation order), `ATT_GATE_CONF` (configuration keys such as night-shift window and wardiya settings).

**Wardiya (وردية)** means a work shift. Employees on a rotating schedule move between wardiyas on a fixed period (7 days by default), and the engine plans the rotation and compares it with what actually happened.

### 4. Absence manager: `EMPLOYEE_ABSENCE_MANAGER`

- Loads active employees and skips weekends and official holidays.
- Detects employees with no attendance for the day.
- Applies excuses: vacation (إجازة), mission (مأمورية), permission (إذن), infectious illness, training, illness, military service and emergency leave.
- Excludes night-shift employees from same-day absence and handles half-day attendance.
- Bulk-inserts absence records, supports manual absence entries, and produces daily and date-range absence reports.

### 5. Scheduler jobs (`DBMS_SCHEDULER`)

| Job | When | What it does |
|---|---|---|
| `READ_FILES_HOURLY_JOB` | Hourly (`FREQ=HOURLY; INTERVAL=1`) | Runs `ATTEND_PKG.PROCESS_ALL_FILES` and loads pending files. |
| `ATT_REPROCESS_PREV_DAY` | Daily at 08:30 | Reprocesses yesterday to catch late punches, mainly night-shift check-outs that arrive after the day closed. |
| `ATT_DAILY_RUN` | Daily at 09:00 | Runs the daily attendance for the current day through the engine and the absence manager. |

The watcher script runs separately on the operating system scheduler (cron on Linux), and only needs to run often enough to keep the queue filled.

## Setup notes

**Schema note:** The DDL files in `sql/tables/` are the available schema exports; some table names differ from those referenced by the live packages. Any tables not included here are proprietary to the company that owns this project and are not published.

- **Oracle:** the code uses `FORALL`, `UTL_FILE` and `DBMS_SCHEDULER`, and includes memory-handling helpers written for older Oracle releases. Test on your target version.
- **Directory object:** create an Oracle directory named `MYDIR` that points to the folder where the device files are stored, and grant the schema read access. `UTL_FILE` can only open files inside that folder, so the watch folder and `MYDIR` must be the same physical location, or files must be copied there.
- **Credentials:** never store the database password in the script. Use an Oracle wallet or a protected environment file readable only by the service account, and have `sqlplus` connect through it.
- **Schema:** create the tables, sequences and reference data (employees, holidays and excuse tables) before compiling the packages. Compile order: ingestion package, attendance engine, absence manager, then create the jobs.
- **Jobs:** create the three scheduler jobs after the packages compile, and check `DBA_SCHEDULER_JOB_RUN_DETAILS` for the first runs.
- **Encoding:** save all `.sql` files as UTF-8 so Arabic comments and weekday names stay readable.

## Known limitations

- The parser reads dates as day/month/year first, so an export that mixes formats can be misread when both day and month are 12 or below.
- A file is recorded as imported before its rows are loaded. If the load fails, delete the file from `ATT_FILE_LOG` before retrying.
- De-duplication and sorting run in PL/SQL loops, which is fine at factory scale but slow on large backlogs.
- Each ingestion run handles one file.

## Future modules

Overtime posting and lateness penalties exist as separate modules on top of the daily results and are not covered here.
