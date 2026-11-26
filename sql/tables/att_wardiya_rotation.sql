--------------------------------------------------------
--  File created - Thursday-November-26-2026   
--------------------------------------------------------
--------------------------------------------------------
--  DDL for Table ATT_WARDIYA_ROTATION
--------------------------------------------------------

  CREATE TABLE "ATT_WARDIYA_ROTATION" ("WARDIYA_COUNT" NUMBER(1,0), "WARDIYA_ID" NUMBER(1,0), "NEXT_WARDIYA" NUMBER(1,0), "PREV_WARDIYA" NUMBER(1,0))
--------------------------------------------------------
--  DDL for Index PK_ATT_WARDIYA_ROTATION
--------------------------------------------------------

  CREATE UNIQUE INDEX "PK_ATT_WARDIYA_ROTATION" ON "ATT_WARDIYA_ROTATION" ("WARDIYA_COUNT", "WARDIYA_ID")
--------------------------------------------------------
--  Constraints for Table ATT_WARDIYA_ROTATION
--------------------------------------------------------

  ALTER TABLE "ATT_WARDIYA_ROTATION" MODIFY ("WARDIYA_COUNT" NOT NULL ENABLE)
  ALTER TABLE "ATT_WARDIYA_ROTATION" MODIFY ("WARDIYA_ID" NOT NULL ENABLE)
  ALTER TABLE "ATT_WARDIYA_ROTATION" MODIFY ("NEXT_WARDIYA" NOT NULL ENABLE)
  ALTER TABLE "ATT_WARDIYA_ROTATION" MODIFY ("PREV_WARDIYA" NOT NULL ENABLE)
  ALTER TABLE "ATT_WARDIYA_ROTATION" ADD CONSTRAINT "CK_ROT_COUNT" CHECK (wardiya_count IN (2, 3)) ENABLE
  ALTER TABLE "ATT_WARDIYA_ROTATION" ADD CONSTRAINT "CK_ROT_NOT_SELF" CHECK (next_wardiya <> wardiya_id AND prev_wardiya <> wardiya_id) ENABLE
  ALTER TABLE "ATT_WARDIYA_ROTATION" ADD CONSTRAINT "PK_ATT_WARDIYA_ROTATION" PRIMARY KEY ("WARDIYA_COUNT", "WARDIYA_ID") USING INDEX  ENABLE
--------------------------------------------------------
--  Ref Constraints for Table ATT_WARDIYA_ROTATION
--------------------------------------------------------

  ALTER TABLE "ATT_WARDIYA_ROTATION" ADD CONSTRAINT "FK_ROT_WARDIYA" FOREIGN KEY ("WARDIYA_ID") REFERENCES "ATT_WARDIYA" ("WARDIYA_ID") ENABLE
  ALTER TABLE "ATT_WARDIYA_ROTATION" ADD CONSTRAINT "FK_ROT_NEXT" FOREIGN KEY ("NEXT_WARDIYA") REFERENCES "ATT_WARDIYA" ("WARDIYA_ID") ENABLE
  ALTER TABLE "ATT_WARDIYA_ROTATION" ADD CONSTRAINT "FK_ROT_PREV" FOREIGN KEY ("PREV_WARDIYA") REFERENCES "ATT_WARDIYA" ("WARDIYA_ID") ENABLE
