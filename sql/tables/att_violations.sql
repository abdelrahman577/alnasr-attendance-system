--------------------------------------------------------
--  File created - Thursday-November-26-2026   
--------------------------------------------------------
--------------------------------------------------------
--  DDL for Table ATT_VIOLATIONS
--------------------------------------------------------

  CREATE TABLE "ATT_VIOLATIONS" ("VIOLATION_ID" NUMBER, "EMP_CODE" NUMBER, "EMP_NAME" VARCHAR2(200), "WORK_DATE" DATE, "SHIFT_ID" NUMBER, "VIOLATION_TYPE" VARCHAR2(30), "VIOLATION_MINUTES" NUMBER, "STATUS" VARCHAR2(20), "NOTES" VARCHAR2(1000), "CREATED_DATE" DATE, "UPDATED_DATE" DATE, "REVIEWED_BY" VARCHAR2(100))
--------------------------------------------------------
--  DDL for Index SYS_C0010770
--------------------------------------------------------

  CREATE UNIQUE INDEX "SYS_C0010770" ON "ATT_VIOLATIONS" ("VIOLATION_ID")
--------------------------------------------------------
--  DDL for Index IDX_VIOLATIONS_EMP_DATE
--------------------------------------------------------

  CREATE INDEX "IDX_VIOLATIONS_EMP_DATE" ON "ATT_VIOLATIONS" ("EMP_CODE", "WORK_DATE")
--------------------------------------------------------
--  DDL for Index IDX_VIOLATIONS_STATUS
--------------------------------------------------------

  CREATE INDEX "IDX_VIOLATIONS_STATUS" ON "ATT_VIOLATIONS" ("STATUS")
--------------------------------------------------------
--  DDL for Index IDX_VIOLATIONS_TYPE
--------------------------------------------------------

  CREATE INDEX "IDX_VIOLATIONS_TYPE" ON "ATT_VIOLATIONS" ("VIOLATION_TYPE")
--------------------------------------------------------
--  Constraints for Table ATT_VIOLATIONS
--------------------------------------------------------

  ALTER TABLE "ATT_VIOLATIONS" ADD CONSTRAINT "CHK_VIOLATION_TYPE" CHECK (VIOLATION_TYPE IN ('LATE', 'EARLY_OUT', 'ABSENT')) ENABLE
  ALTER TABLE "ATT_VIOLATIONS" ADD CONSTRAINT "CHK_VIOLATION_STATUS" CHECK (STATUS IN ('PENDING', 'REVIEWED', 'CANCELLED', 'EXEMPTED')) ENABLE
  ALTER TABLE "ATT_VIOLATIONS" ADD PRIMARY KEY ("VIOLATION_ID") USING INDEX  ENABLE
