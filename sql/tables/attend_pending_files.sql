--------------------------------------------------------
--  File created - Thursday-November-26-2026   
--------------------------------------------------------
--------------------------------------------------------
--  DDL for Table ATTEND_PENDING_FILES
--------------------------------------------------------

  CREATE TABLE "ATTEND_PENDING_FILES" ("FILE_NAME" VARCHAR2(400), "ADDED_DATE" DATE DEFAULT SYSDATE, "STATUS" VARCHAR2(20) DEFAULT 'PENDING', "PROCESSED_DATE" DATE, "ERROR_MESSAGE" VARCHAR2(4000))
--------------------------------------------------------
--  DDL for Index SYS_C0010553
--------------------------------------------------------

  CREATE UNIQUE INDEX "SYS_C0010553" ON "ATTEND_PENDING_FILES" ("FILE_NAME")
--------------------------------------------------------
--  DDL for Index IDX_PENDING_STATUS
--------------------------------------------------------

  CREATE INDEX "IDX_PENDING_STATUS" ON "ATTEND_PENDING_FILES" ("STATUS")
--------------------------------------------------------
--  Constraints for Table ATTEND_PENDING_FILES
--------------------------------------------------------

  ALTER TABLE "ATTEND_PENDING_FILES" ADD PRIMARY KEY ("FILE_NAME") USING INDEX  ENABLE
