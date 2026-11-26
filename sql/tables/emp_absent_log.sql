--------------------------------------------------------
--  File created - Thursday-November-26-2026   
--------------------------------------------------------
--------------------------------------------------------
--  DDL for Table EMP_ABSENT_LOG
--------------------------------------------------------

  CREATE TABLE "EMP_ABSENT_LOG" ("LOG_ID" NUMBER, "EMP_CODE" NUMBER, "LOG_DATE" DATE, "LOG_STEP" VARCHAR2(200), "LOG_MESSAGE" VARCHAR2(500), "WORK_DATE" DATE)
--------------------------------------------------------
--  DDL for Index SYS_C0010459
--------------------------------------------------------

  CREATE UNIQUE INDEX "SYS_C0010459" ON "EMP_ABSENT_LOG" ("LOG_ID")
--------------------------------------------------------
--  Constraints for Table EMP_ABSENT_LOG
--------------------------------------------------------

  ALTER TABLE "EMP_ABSENT_LOG" ADD PRIMARY KEY ("LOG_ID") USING INDEX  ENABLE
--------------------------------------------------------
--  Ref Constraints for Table EMP_ABSENT_LOG
--------------------------------------------------------

  ALTER TABLE "EMP_ABSENT_LOG" ADD FOREIGN KEY ("EMP_CODE") REFERENCES "EMP_IMPORT" ("EMP_CODE") ENABLE
