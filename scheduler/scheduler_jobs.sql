BEGIN
    DBMS_SCHEDULER.CREATE_JOB (
        job_name        => 'READ_FILES_HOURLY_JOB',
        job_type        => 'PLSQL_BLOCK',
        job_action      => 'BEGIN ATTEND_PKG.PROCESS_ALL_FILES; END;',
        start_date      => SYSTIMESTAMP,
        repeat_interval => 'FREQ=MINUTELY; INTERVAL=0',
        enabled         => TRUE,
        comments        => '????? ????? ?????? ?? ????'
    );
END;
/



BEGIN
  -- Job 1: reprocess yesterday at 08:30
  DBMS_SCHEDULER.CREATE_JOB(
    job_name        => 'ATT_REPROCESS_PREV_DAY',
    job_type        => 'STORED_PROCEDURE',
    job_action      => 'ATT_JOB_PKG.JOB_REPROCESS_PREV_DAY',
    start_date      => SYSTIMESTAMP,
    repeat_interval => 'FREQ=DAILY; BYHOUR=8; BYMINUTE=30; BYSECOND=0',
    enabled         => TRUE,
    auto_drop       => FALSE,
    comments        => 'Reprocess yesterday punches (late OUT after DB close)'
  );

  -- Job 2: daily attendance for today at 09:00
  DBMS_SCHEDULER.CREATE_JOB(
    job_name        => 'ATT_DAILY_RUN',
    job_type        => 'STORED_PROCEDURE',
    job_action      => 'ATT_JOB_PKG.JOB_DAILY_RUN',
    start_date      => SYSTIMESTAMP,
    repeat_interval => 'FREQ=DAILY; BYHOUR=9; BYMINUTE=0; BYSECOND=0',
    enabled         => TRUE,
    auto_drop       => FALSE,
    comments        => 'Run daily attendance for current day'
  );
END;
/
