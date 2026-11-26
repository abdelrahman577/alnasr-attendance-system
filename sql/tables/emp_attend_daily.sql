--------------------------------------------------------
--  File created - Thursday-November-26-2026   
--------------------------------------------------------
--------------------------------------------------------
--  DDL for Table EMP_ATTEND_DAILY
--------------------------------------------------------

  CREATE TABLE "EMP_ATTEND_DAILY" ("DAILY_ID" NUMBER, "EMP_CODE" NUMBER, "EMP_NAME" VARCHAR2(200), "DEPARTMENT" VARCHAR2(100), "WORK_DATE" DATE, "WEEKDAY" VARCHAR2(20), "SHIFT_ID" NUMBER, "SHIFT_TYPE" VARCHAR2(50), "FIRST_IN" DATE, "LAST_OUT" DATE, "WORK_MIN" NUMBER(6,0), "TOTAL_HOURS" NUMBER(6,2), "RAW_PUNCH_COUNT" NUMBER(3,0), "ATTEND_STATUS" VARCHAR2(30), "OVERTIME_MIN" NUMBER(6,0), "LATE_MIN" NUMBER(6,0), "EARLY_OUT_MIN" NUMBER(6,0), "OVERTIME_HOURS" NUMBER(6,2), "LATE_HOURS" NUMBER(6,2), "EARLY_OUT_HOURS" NUMBER(6,2), "IS_NIGHT" CHAR(1) DEFAULT 'N', "PROCESS_FLAG" CHAR(1) DEFAULT 'N', "SOURCE" VARCHAR2(50) DEFAULT 'AUTO_ASSIGN', "NOTES" VARCHAR2(1000), "FILE_NAME" VARCHAR2(400), "CREATED_AT" DATE DEFAULT SYSDATE, "CREATED_BY" VARCHAR2(50) DEFAULT USER, "UPDATED_AT" DATE, "UPDATED_BY" VARCHAR2(50), "EARLY_IN_MIN" NUMBER, "EARLY_IN_HOUR" NUMBER, "NIGHT_WORK_MIN" NUMBER, "NIGHT_WORK_HOUR" NUMBER, "PLANNED_WARDIYA" NUMBER(1,0), "ACTUAL_WARDIYA" NUMBER(1,0), "WARDIYA_RESULT" VARCHAR2(10), "WARDIYA_SKIP_REASON" VARCHAR2(60))
--------------------------------------------------------
--  DDL for Index IDX_DAILY_NIGHT
--------------------------------------------------------

  CREATE INDEX "IDX_DAILY_NIGHT" ON "EMP_ATTEND_DAILY" ("IS_NIGHT", "WORK_DATE")
--------------------------------------------------------
--  DDL for Index IDX_DAILY_EMP_WORK
--------------------------------------------------------

  CREATE INDEX "IDX_DAILY_EMP_WORK" ON "EMP_ATTEND_DAILY" ("EMP_CODE", "WORK_DATE", "ATTEND_STATUS")
--------------------------------------------------------
--  DDL for Index IDX_DAILY_SUMMARY
--------------------------------------------------------

  CREATE INDEX "IDX_DAILY_SUMMARY" ON "EMP_ATTEND_DAILY" ("WORK_DATE", "ATTEND_STATUS", "TOTAL_HOURS", "LATE_MIN", "OVERTIME_MIN")
--------------------------------------------------------
--  DDL for Index IDX_DAILY_DEPT_SUMMARY
--------------------------------------------------------

  CREATE INDEX "IDX_DAILY_DEPT_SUMMARY" ON "EMP_ATTEND_DAILY" ("WORK_DATE", "DEPARTMENT", "ATTEND_STATUS", "TOTAL_HOURS")
--------------------------------------------------------
--  DDL for Index IDX_DAILY_SHIFT_SUMMARY
--------------------------------------------------------

  CREATE INDEX "IDX_DAILY_SHIFT_SUMMARY" ON "EMP_ATTEND_DAILY" ("WORK_DATE", "SHIFT_TYPE", "ATTEND_STATUS", "TOTAL_HOURS")
--------------------------------------------------------
--  DDL for Index IDX_DAILY_SUPER
--------------------------------------------------------

  CREATE INDEX "IDX_DAILY_SUPER" ON "EMP_ATTEND_DAILY" ("WORK_DATE", "EMP_CODE", "ATTEND_STATUS", "TOTAL_HOURS")
--------------------------------------------------------
--  DDL for Index IDX_DAILY_WORK_DATE
--------------------------------------------------------

  CREATE INDEX "IDX_DAILY_WORK_DATE" ON "EMP_ATTEND_DAILY" ("WORK_DATE")
--------------------------------------------------------
--  DDL for Index IDX_DAILY_EMP_DATE
--------------------------------------------------------

  CREATE INDEX "IDX_DAILY_EMP_DATE" ON "EMP_ATTEND_DAILY" ("EMP_CODE", "WORK_DATE")
--------------------------------------------------------
--  DDL for Index IDX_DAILY_STATUS
--------------------------------------------------------

  CREATE INDEX "IDX_DAILY_STATUS" ON "EMP_ATTEND_DAILY" ("ATTEND_STATUS")
--------------------------------------------------------
--  DDL for Index IDX_DAILY_SHIFT
--------------------------------------------------------

  CREATE INDEX "IDX_DAILY_SHIFT" ON "EMP_ATTEND_DAILY" ("SHIFT_ID")
--------------------------------------------------------
--  DDL for Index IDX_DAILY_DEPT
--------------------------------------------------------

  CREATE INDEX "IDX_DAILY_DEPT" ON "EMP_ATTEND_DAILY" ("DEPARTMENT")
--------------------------------------------------------
--  DDL for Index IDX_DAILY_PROCESS
--------------------------------------------------------

  CREATE INDEX "IDX_DAILY_PROCESS" ON "EMP_ATTEND_DAILY" ("PROCESS_FLAG", "WORK_DATE")
--------------------------------------------------------
--  DDL for Index SYS_C0010471
--------------------------------------------------------

  CREATE UNIQUE INDEX "SYS_C0010471" ON "EMP_ATTEND_DAILY" ("DAILY_ID")
--------------------------------------------------------
--  Constraints for Table EMP_ATTEND_DAILY
--------------------------------------------------------

  ALTER TABLE "EMP_ATTEND_DAILY" ADD CONSTRAINT "CK_DAILY_WARDIYA_RESULT" CHECK (wardiya_result IN ('LEARNED', 'MATCH', 'MISMATCH', 'SKIPPED')) ENABLE
  ALTER TABLE "EMP_ATTEND_DAILY" MODIFY ("EMP_CODE" NOT NULL ENABLE)
  ALTER TABLE "EMP_ATTEND_DAILY" MODIFY ("EMP_NAME" NOT NULL ENABLE)
  ALTER TABLE "EMP_ATTEND_DAILY" MODIFY ("WORK_DATE" NOT NULL ENABLE)
  ALTER TABLE "EMP_ATTEND_DAILY" ADD CHECK (is_night IN ('Y','N')) ENABLE
  ALTER TABLE "EMP_ATTEND_DAILY" ADD CHECK (process_flag IN ('N','P','Y','E')) ENABLE
  ALTER TABLE "EMP_ATTEND_DAILY" ADD CONSTRAINT "CHK_DAILY_ATTEND_STATUS" CHECK (attend_status IN (
        'ABSENT','PRESENT','LATE','LATE_SEVERE','HALF_DAY','FULL_DAY',
        'INCOMPLETE','EXCUSED_ABSENCE','VACATION','SICK_LEAVE','MISSION',
        'PERMISSION','TRAINING','EMERGENCY'
    )) ENABLE
  ALTER TABLE "EMP_ATTEND_DAILY" ADD PRIMARY KEY ("DAILY_ID") USING INDEX  ENABLE
--------------------------------------------------------
--  Ref Constraints for Table EMP_ATTEND_DAILY
--------------------------------------------------------

  ALTER TABLE "EMP_ATTEND_DAILY" ADD CONSTRAINT "FK_DAILY_PLANNED_WARDIYA" FOREIGN KEY ("PLANNED_WARDIYA") REFERENCES "ATT_WARDIYA" ("WARDIYA_ID") ENABLE
  ALTER TABLE "EMP_ATTEND_DAILY" ADD CONSTRAINT "FK_DAILY_ACTUAL_WARDIYA" FOREIGN KEY ("ACTUAL_WARDIYA") REFERENCES "ATT_WARDIYA" ("WARDIYA_ID") ENABLE
  ALTER TABLE "EMP_ATTEND_DAILY" ADD FOREIGN KEY ("EMP_CODE") REFERENCES "EMP_IMPORT" ("EMP_CODE") ENABLE
  ALTER TABLE "EMP_ATTEND_DAILY" ADD FOREIGN KEY ("SHIFT_ID") REFERENCES "ATT_EMP_SHIFT" ("SHIFT_ID") ENABLE
