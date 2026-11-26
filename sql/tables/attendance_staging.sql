--------------------------------------------------------
--  File created - Thursday-November-26-2026   
--------------------------------------------------------
--------------------------------------------------------
--  DDL for Table ATTENDANCE_STAGING
--------------------------------------------------------

  CREATE TABLE "ATTENDANCE_STAGING" ("STAGE_ID" NUMBER, "EMP_CODE" NUMBER, "FIRST_NAME" VARCHAR2(100), "LAST_NAME" VARCHAR2(100), "DEPARTMENT" VARCHAR2(100), "WORK_DATE" DATE, "WEEKDAY" VARCHAR2(20), "PUNCH_TIME" DATE, "PUNCH_STATUS" VARCHAR2(20), "FILE_NAME" VARCHAR2(400), "LOAD_DATE" DATE DEFAULT SYSDATE, "PROCESS_FLAG" CHAR(1) DEFAULT 'N', "SESSION_ID" NUMBER, "SESSION_OPEN" CHAR(1) DEFAULT 'N', "LINKED_SESSION" NUMBER)
--------------------------------------------------------
--  DDL for Index IDX_ATTEND_STAGING_EMP_DATE
--------------------------------------------------------

  CREATE INDEX "IDX_ATTEND_STAGING_EMP_DATE" ON "ATTENDANCE_STAGING" ("EMP_CODE", "WORK_DATE", "PROCESS_FLAG")
--------------------------------------------------------
--  DDL for Index IDX_ATT_STAGING_UNIQUE
--------------------------------------------------------

  CREATE UNIQUE INDEX "IDX_ATT_STAGING_UNIQUE" ON "ATTENDANCE_STAGING" ("EMP_CODE", "SESSION_ID", "PUNCH_TIME", "PUNCH_STATUS")
--------------------------------------------------------
--  DDL for Index SYS_C0010496
--------------------------------------------------------

  CREATE UNIQUE INDEX "SYS_C0010496" ON "ATTENDANCE_STAGING" ("STAGE_ID")
--------------------------------------------------------
--  DDL for Index IDX_STAGING_PROCESS
--------------------------------------------------------

  CREATE INDEX "IDX_STAGING_PROCESS" ON "ATTENDANCE_STAGING" ("PROCESS_FLAG", "WORK_DATE")
--------------------------------------------------------
--  DDL for Index IDX_STAGING_EMP_DATE
--------------------------------------------------------

  CREATE INDEX "IDX_STAGING_EMP_DATE" ON "ATTENDANCE_STAGING" ("EMP_CODE", "WORK_DATE")
--------------------------------------------------------
--  DDL for Index IDX_STAGING_FILE
--------------------------------------------------------

  CREATE INDEX "IDX_STAGING_FILE" ON "ATTENDANCE_STAGING" ("FILE_NAME")
--------------------------------------------------------
--  DDL for Index IDX_STAGING_STATUS_DATE
--------------------------------------------------------

  CREATE INDEX "IDX_STAGING_STATUS_DATE" ON "ATTENDANCE_STAGING" ("PUNCH_STATUS", "WORK_DATE")
--------------------------------------------------------
--  Constraints for Table ATTENDANCE_STAGING
--------------------------------------------------------

  ALTER TABLE "ATTENDANCE_STAGING" MODIFY ("WORK_DATE" NOT NULL ENABLE)
  ALTER TABLE "ATTENDANCE_STAGING" ADD CHECK (process_flag IN ('N','P','Y','E')) ENABLE
  ALTER TABLE "ATTENDANCE_STAGING" ADD PRIMARY KEY ("STAGE_ID") USING INDEX  ENABLE
--------------------------------------------------------
--  Ref Constraints for Table ATTENDANCE_STAGING
--------------------------------------------------------

  ALTER TABLE "ATTENDANCE_STAGING" ADD FOREIGN KEY ("EMP_CODE") REFERENCES "EMP_IMPORT" ("EMP_CODE") ENABLE
