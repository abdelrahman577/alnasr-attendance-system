--------------------------------------------------------
--  File created - Thursday-November-26-2026   
--------------------------------------------------------
--------------------------------------------------------
--  DDL for Table ATT_MOVES
--------------------------------------------------------

  CREATE TABLE "ATT_MOVES" ("ID" NUMBER, "EMP_CODE" NUMBER, "EMP_NAME" VARCHAR2(100), "WORK_DATE" DATE, "MOVE_COUNT" NUMBER, "SESSION_ID" NUMBER, "SHIFT_TYPE" VARCHAR2(50), "CREATED_DATE" DATE DEFAULT SYSDATE, "NOTES" VARCHAR2(500))
--------------------------------------------------------
--  DDL for Index SYS_C0010747
--------------------------------------------------------

  CREATE UNIQUE INDEX "SYS_C0010747" ON "ATT_MOVES" ("ID")
--------------------------------------------------------
--  Constraints for Table ATT_MOVES
--------------------------------------------------------

  ALTER TABLE "ATT_MOVES" ADD PRIMARY KEY ("ID") USING INDEX  ENABLE
