--------------------------------------------------------
--  File created - Thursday-November-26-2026   
--------------------------------------------------------
--------------------------------------------------------
--  DDL for Table ATT_EMP_SHIFT
--------------------------------------------------------

  CREATE TABLE "ATT_EMP_SHIFT" ("SHIFT_ID" NUMBER, "SHIFT_TYPE" VARCHAR2(20), "START_TIME" DATE, "END_TIME" DATE, "IS_NIGHT" CHAR(1), "WORK_MIN" NUMBER, "ALLOW_LATE_MIN" NUMBER, "ALLOW_EARLY_MIN" NUMBER, "ACTIVE_FLAG" CHAR(1), "CREATED_AT" DATE DEFAULT sysdate, "SHIFT_FLAG" NUMBER(1,0), "WARDIYA_ID" NUMBER)
--------------------------------------------------------
--  DDL for Index IDX_SHIFT_ACTIVE
--------------------------------------------------------

  CREATE INDEX "IDX_SHIFT_ACTIVE" ON "ATT_EMP_SHIFT" ("ACTIVE_FLAG", "SHIFT_TYPE")
--------------------------------------------------------
--  DDL for Index IDX_SHIFT_NIGHT
--------------------------------------------------------

  CREATE INDEX "IDX_SHIFT_NIGHT" ON "ATT_EMP_SHIFT" ("IS_NIGHT", "ACTIVE_FLAG") 
  PCTFREE 10 INITRANS 2 MAXTRANS 255 COMPUTE STATISTICS 
  STORAGE(INITIAL 65536 NEXT 1048576 MINEXTENTS 1 MAXEXTENTS 2147483645
  PCTINCREASE 0 FREELISTS 1 FREELIST GROUPS 1
  BUFFER_POOL DEFAULT FLASH_CACHE DEFAULT CELL_FLASH_CACHE DEFAULT)
  TABLESPACE "SYSAUX" ;
--------------------------------------------------------
--  DDL for Index SYS_C0010434
--------------------------------------------------------

  CREATE UNIQUE INDEX "SYS_C0010434" ON "ATT_EMP_SHIFT" ("SHIFT_ID")
--------------------------------------------------------
--  Constraints for Table ATT_EMP_SHIFT
--------------------------------------------------------

  ALTER TABLE "ATT_EMP_SHIFT" ADD CHECK (is_night in ('Y', 'N')) ENABLE
  ALTER TABLE "ATT_EMP_SHIFT" ADD CHECK (active_flag in ('Y', 'N')) ENABLE
  ALTER TABLE "ATT_EMP_SHIFT" ADD PRIMARY KEY ("SHIFT_ID") USING INDEX  ENABLE
--------------------------------------------------------
--  Ref Constraints for Table ATT_EMP_SHIFT
--------------------------------------------------------

  ALTER TABLE "ATT_EMP_SHIFT" ADD CONSTRAINT "FK_SHIFT_WARDIYA" FOREIGN KEY ("WARDIYA_ID") REFERENCES "ATT_WARDIYA" ("WARDIYA_ID") ENABLE
