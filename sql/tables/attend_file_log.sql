--------------------------------------------------------
--  File created - Thursday-November-26-2026   
--------------------------------------------------------
--------------------------------------------------------
--  DDL for Table ATTEND_FILE_LOG
--------------------------------------------------------

  CREATE TABLE "ATTEND_FILE_LOG" ("FILE_NAME" VARCHAR2(400), "IMPORT_DATE" DATE DEFAULT sysdate)
--------------------------------------------------------
--  DDL for Index SYS_C009721
--------------------------------------------------------

  CREATE UNIQUE INDEX "SYS_C009721" ON "ATTEND_FILE_LOG" ("FILE_NAME")
--------------------------------------------------------
--  Constraints for Table ATTEND_FILE_LOG
--------------------------------------------------------

  ALTER TABLE "ATTEND_FILE_LOG" ADD UNIQUE ("FILE_NAME") USING INDEX  ENABLE
