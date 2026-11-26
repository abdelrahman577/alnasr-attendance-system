--------------------------------------------------------
--  File created - Thursday-November-26-2026   
--------------------------------------------------------
--------------------------------------------------------
--  DDL for Table ATT_GATE_CONF
--------------------------------------------------------

  CREATE TABLE "ATT_GATE_CONF" ("CONF_KEY" VARCHAR2(50), "CONF_VALUE" VARCHAR2(100), "UPDATED_AT" DATE DEFAULT SYSDATE)
--------------------------------------------------------
--  DDL for Index SYS_C0011351
--------------------------------------------------------

  CREATE UNIQUE INDEX "SYS_C0011351" ON "ATT_GATE_CONF" ("CONF_KEY")
--------------------------------------------------------
--  Constraints for Table ATT_GATE_CONF
--------------------------------------------------------

  ALTER TABLE "ATT_GATE_CONF" MODIFY ("CONF_VALUE" NOT NULL ENABLE)
  ALTER TABLE "ATT_GATE_CONF" ADD PRIMARY KEY ("CONF_KEY") USING INDEX  ENABLE
