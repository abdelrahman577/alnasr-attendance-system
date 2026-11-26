--------------------------------------------------------
--  File created - Thursday-November-26-2026   
--------------------------------------------------------
--------------------------------------------------------
--  DDL for Table ATTEND_PARSE_ERRORS
--------------------------------------------------------

  CREATE TABLE "ATTEND_PARSE_ERRORS" ("ERROR_ID" NUMBER, "FILE_NAME" VARCHAR2(500), "ERROR_LINE" VARCHAR2(4000), "ERROR_MESSAGE" VARCHAR2(4000), "LOG_DATE" DATE DEFAULT SYSDATE)
--------------------------------------------------------
--  DDL for Index SYS_C0010360
--------------------------------------------------------

  CREATE UNIQUE INDEX "SYS_C0010360" ON "ATTEND_PARSE_ERRORS" ("ERROR_ID")
--------------------------------------------------------
--  Constraints for Table ATTEND_PARSE_ERRORS
--------------------------------------------------------

  ALTER TABLE "ATTEND_PARSE_ERRORS" ADD PRIMARY KEY ("ERROR_ID") USING INDEX  ENABLE
