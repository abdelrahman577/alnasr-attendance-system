--------------------------------------------------------
--  File created - Thursday-November-26-2026   
--------------------------------------------------------
--------------------------------------------------------
--  DDL for Table ATT_WARDIYA_TRANSFER
--------------------------------------------------------

  CREATE TABLE "ATT_WARDIYA_TRANSFER" ("TRANSFER_ID" NUMBER, "EMP_CODE" NUMBER, "EFFECTIVE_DATE" DATE, "NEW_WARDIYA" NUMBER(1,0), "REASON" VARCHAR2(500), "STATUS" VARCHAR2(10) DEFAULT 'APPLIED', "CREATED_BY" VARCHAR2(30), "CREATED_AT" DATE DEFAULT SYSDATE)
--------------------------------------------------------
--  DDL for Index PK_ATT_WARDIYA_TRANSFER
--------------------------------------------------------

  CREATE UNIQUE INDEX "PK_ATT_WARDIYA_TRANSFER" ON "ATT_WARDIYA_TRANSFER" ("TRANSFER_ID")
--------------------------------------------------------
--  DDL for Index IX_AWT_EMP_EFF
--------------------------------------------------------

  CREATE INDEX "IX_AWT_EMP_EFF" ON "ATT_WARDIYA_TRANSFER" ("EMP_CODE", "EFFECTIVE_DATE")
--------------------------------------------------------
--  Constraints for Table ATT_WARDIYA_TRANSFER
--------------------------------------------------------

  ALTER TABLE "ATT_WARDIYA_TRANSFER" MODIFY ("TRANSFER_ID" NOT NULL ENABLE)
  ALTER TABLE "ATT_WARDIYA_TRANSFER" MODIFY ("EMP_CODE" NOT NULL ENABLE)
  ALTER TABLE "ATT_WARDIYA_TRANSFER" MODIFY ("EFFECTIVE_DATE" NOT NULL ENABLE)
  ALTER TABLE "ATT_WARDIYA_TRANSFER" MODIFY ("NEW_WARDIYA" NOT NULL ENABLE)
  ALTER TABLE "ATT_WARDIYA_TRANSFER" MODIFY ("STATUS" NOT NULL ENABLE)
  ALTER TABLE "ATT_WARDIYA_TRANSFER" ADD CONSTRAINT "CK_AWT_STATUS" CHECK (status IN ('APPLIED', 'REVERSED')) ENABLE
  ALTER TABLE "ATT_WARDIYA_TRANSFER" ADD CONSTRAINT "PK_ATT_WARDIYA_TRANSFER" PRIMARY KEY ("TRANSFER_ID") USING INDEX  ENABLE
--------------------------------------------------------
--  Ref Constraints for Table ATT_WARDIYA_TRANSFER
--------------------------------------------------------

  ALTER TABLE "ATT_WARDIYA_TRANSFER" ADD FOREIGN KEY ("EMP_CODE") REFERENCES "EMP_IMPORT" ("EMP_CODE") ENABLE
  ALTER TABLE "ATT_WARDIYA_TRANSFER" ADD CONSTRAINT "FK_AWT_NEW_WARDIYA" FOREIGN KEY ("NEW_WARDIYA") REFERENCES "ATT_WARDIYA" ("WARDIYA_ID") ENABLE
