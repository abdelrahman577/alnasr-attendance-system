--------------------------------------------------------
--  File created - Thursday-November-26-2026   
--------------------------------------------------------
--------------------------------------------------------
--  DDL for Table ATTEND_DAY_LOCK
--------------------------------------------------------

  CREATE TABLE "ATTEND_DAY_LOCK" ("WORK_DATE" DATE, "STATUS" CHAR(1), "LOCKED_BY" VARCHAR2(50), "LOCKED_AT" DATE, "UNLOCKED_AT" DATE, "NOTES" VARCHAR2(200))
--------------------------------------------------------
--  DDL for Index SYS_C0010274
--------------------------------------------------------

  CREATE UNIQUE INDEX "SYS_C0010274" ON "ATTEND_DAY_LOCK" ("WORK_DATE")
--------------------------------------------------------
--  Constraints for Table ATTEND_DAY_LOCK
--------------------------------------------------------

  ALTER TABLE "ATTEND_DAY_LOCK" ADD CHECK (status in ('L' , 'U')) ENABLE
  ALTER TABLE "ATTEND_DAY_LOCK" ADD PRIMARY KEY ("WORK_DATE") USING INDEX  ENABLE
