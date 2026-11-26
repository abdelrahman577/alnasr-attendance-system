--------------------------------------------------------
--  File created - Thursday-November-26-2026   
--------------------------------------------------------
--------------------------------------------------------
--  DDL for Table EMP_ATTEND_LOG
--------------------------------------------------------

  CREATE TABLE "EMP_ATTEND_LOG" ("LOG_ID" NUMBER, "EMP_CODE" NUMBER, "LOG_DATE" DATE, "LOG_STEP" VARCHAR2(200), "LOG_MESSAGE" VARCHAR2(500), "WORK_DATE" DATE)
--------------------------------------------------------
--  DDL for Index SYS_C0010498
--------------------------------------------------------

  CREATE UNIQUE INDEX "SYS_C0010498" ON "EMP_ATTEND_LOG" ("LOG_ID")
--------------------------------------------------------
--  DDL for Index IDX_LOG_DATE
--------------------------------------------------------

  CREATE INDEX "IDX_LOG_DATE" ON "EMP_ATTEND_LOG" ("LOG_DATE")
--------------------------------------------------------
--  DDL for Index IDX_LOG_WORKDATE
--------------------------------------------------------

  CREATE INDEX "IDX_LOG_WORKDATE" ON "EMP_ATTEND_LOG" ("WORK_DATE")
--------------------------------------------------------
--  DDL for Index IDX_LOG_EMP
--------------------------------------------------------

  CREATE INDEX "IDX_LOG_EMP" ON "EMP_ATTEND_LOG" ("EMP_CODE")
--------------------------------------------------------
--  Constraints for Table EMP_ATTEND_LOG
--------------------------------------------------------

  ALTER TABLE "EMP_ATTEND_LOG" ADD PRIMARY KEY ("LOG_ID") USING INDEX  ENABLE
--------------------------------------------------------
--  Ref Constraints for Table EMP_ATTEND_LOG
--------------------------------------------------------

  ALTER TABLE "EMP_ATTEND_LOG" ADD FOREIGN KEY ("EMP_CODE") REFERENCES "EMP_IMPORT" ("EMP_CODE") ENABLE
