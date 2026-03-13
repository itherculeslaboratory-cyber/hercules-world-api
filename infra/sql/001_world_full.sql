BEGIN;  
  
CREATE EXTENSION IF NOT EXISTS pgcrypto;  
  
-- SCHEMA  
CREATE SCHEMA IF NOT EXISTS core;  
CREATE SCHEMA IF NOT EXISTS derived;  
CREATE SCHEMA IF NOT EXISTS market;  
CREATE SCHEMA IF NOT EXISTS raw;  
CREATE SCHEMA IF NOT EXISTS semantic;  
CREATE SCHEMA IF NOT EXISTS universe;  
  
-- =====================================================  
-- DERIVED  
-- =====================================================  
  
CREATE TABLE derived.feature_value (  
  feature_value_id uuid PRIMARY KEY,  
  entity_id uuid NOT NULL,  
  feature_name text NOT NULL,  
  numeric_value numeric NOT NULL,  
  created_at timestamptz NOT NULL DEFAULT now(),  
  value_hash text NOT NULL,  
  UNIQUE(entity_id, feature_name)  
);  
  
CREATE INDEX idx_feature_entity ON derived.feature_value(entity_id);  
CREATE INDEX idx_feature_lookup ON derived.feature_value(feature_name, numeric_value, entity_id);
CREATE OR REPLACE FUNCTION derived.compute_value_hash(  
  p_entity uuid,  
  p_feature text,  
  p_numeric numeric  
) RETURNS text LANGUAGE sql IMMUTABLE AS $$  
SELECT encode(  
  digest(  
    p_entity::text || ':' ||  
    p_feature || ':' ||  
    to_char(p_numeric,'FM999999999999999999999999999.############################'),  
  'sha256'),  
'hex');  
$$;  
  
CREATE OR REPLACE FUNCTION derived.upsert_feature(  
  p_entity uuid,  
  p_feature text,  
  p_numeric numeric  
) RETURNS void LANGUAGE plpgsql AS $$  
BEGIN  
  INSERT INTO derived.feature_value(  
    feature_value_id, entity_id, feature_name,  
    numeric_value, value_hash  
  )  
  VALUES (  
    gen_random_uuid(),  
    p_entity,  
    p_feature,  
    p_numeric,  
    derived.compute_value_hash(p_entity,p_feature,p_numeric)  
  )
ON CONFLICT (entity_id,feature_name)  
  DO UPDATE SET  
    numeric_value = EXCLUDED.numeric_value,  
    value_hash = derived.compute_value_hash(  
      p_entity,p_feature,EXCLUDED.numeric_value  
    );  
END;  
$$;

-- =====================================================  
-- UNIVERSE  
-- =====================================================  
  
CREATE TABLE universe.universe_snapshot (  
  universe_id uuid NOT NULL,  
  snapshot_version text NOT NULL,  
  created_at timestamptz NOT NULL DEFAULT now(),  
  PRIMARY KEY (universe_id, snapshot_version)  
);  
  
CREATE INDEX idx_universe_snapshot_lookup  
  ON universe.universe_snapshot(universe_id, created_at DESC, snapshot_version);  
  
CREATE TABLE universe.universe_entity_score (  
  universe_id uuid NOT NULL,  
  snapshot_version text NOT NULL,  
  entity_id uuid NOT NULL,  
  score numeric NOT NULL,  
  created_at timestamptz NOT NULL DEFAULT now(),  
  PRIMARY KEY (universe_id, snapshot_version, entity_id),  
  FOREIGN KEY (universe_id, snapshot_version)  
    REFERENCES universe.universe_snapshot(universe_id, snapshot_version)  
    ON DELETE CASCADE  
);

CREATE OR REPLACE FUNCTION universe.length_prefix_concat(parts text[])  
RETURNS text LANGUAGE plpgsql IMMUTABLE AS $$  
DECLARE  
  r text := '';  
  p text;  
BEGIN  
  FOREACH p IN ARRAY parts LOOP  
    r := r || length(p)::text || ':' || p || '|';  
  END LOOP;  
  RETURN r;  
END;  
$$;  
  
CREATE OR REPLACE FUNCTION universe.generate_snapshot(p_universe uuid)  
RETURNS text LANGUAGE plpgsql AS $$  
DECLARE  
  v_input text;  
  v_snapshot text;  
BEGIN  
  PERFORM pg_advisory_xact_lock(hashtext(p_universe::text));  
  
  SELECT universe.length_prefix_concat(  
    ARRAY[  
      p_universe::text,  
      string_agg(value_hash, ',' ORDER BY entity_id, feature_name)  
    ]  
  )
INTO v_input  
  FROM derived.feature_value;  
  
  v_snapshot := encode(digest(v_input,'sha256'),'hex');  
  
  INSERT INTO universe.universe_snapshot(universe_id,snapshot_version)  
  VALUES (p_universe,v_snapshot)  
  ON CONFLICT DO NOTHING;  
  
  RETURN v_snapshot;  
END;  
$$;  
  
CREATE OR REPLACE FUNCTION universe.refresh_scores(p_universe uuid)  
RETURNS text LANGUAGE plpgsql AS $$  
DECLARE  
  v_snapshot text;  
BEGIN  
  v_snapshot := universe.generate_snapshot(p_universe);  
  
  INSERT INTO universe.universe_entity_score(  
    universe_id,snapshot_version,entity_id,score  
  )  
  SELECT  
    p_universe,  
    v_snapshot,  
    entity_id,  
    numeric_value  
  FROM derived.feature_value  
  ON CONFLICT DO NOTHING;  
  
  RETURN v_snapshot;  
END;  
$$;
-- =====================================================  
-- CORE  
-- =====================================================  
  
CREATE TABLE core.entity (  
  entity_id uuid PRIMARY KEY,  
  created_at timestamptz NOT NULL DEFAULT now()  
);  
  
CREATE TABLE core.schema_migrations (  
  version text PRIMARY KEY,  
  executed_at timestamptz NOT NULL DEFAULT now(),  
  checksum text NOT NULL DEFAULT '',  
  duration_ms integer  
);  
  
CREATE TABLE core.ui_document (  
  ui_document_id uuid PRIMARY KEY,  
  universe_id uuid NOT NULL,  
  owner_subject uuid NOT NULL,  
  forked_from_ui_document_id uuid REFERENCES core.ui_document(ui_document_id),  
  created_at timestamptz NOT NULL DEFAULT now()  
);

CREATE TABLE core.ui_document_version (  
  ui_document_version_id uuid PRIMARY KEY,  
  ui_document_id uuid NOT NULL REFERENCES core.ui_document(ui_document_id),  
  version integer NOT NULL CHECK (version >= 1),  
  title text NOT NULL CHECK (char_length(title) BETWEEN 1 AND 200),  
  description text NOT NULL DEFAULT '' CHECK (char_length(description) <= 2000),  
  visibility text NOT NULL CHECK (visibility IN ('PRIVATE','PUBLIC')),  
  ui_schema_version text NOT NULL CHECK (ui_schema_version = 'v1'),  
  schema_json jsonb NOT NULL CHECK (jsonb_typeof(schema_json) = 'object'),  
  schema_hash text NOT NULL CHECK (schema_hash ~ '^[0-9a-f]{64}$'),  
  created_at timestamptz NOT NULL DEFAULT now(),  
  UNIQUE (ui_document_id, version),  
  UNIQUE (ui_document_id, schema_hash)  
);  
  
CREATE INDEX idx_ui_document_universe_created  
  ON core.ui_document(universe_id, created_at DESC, ui_document_id);


CREATE INDEX idx_ui_document_version_doc_version  
  ON core.ui_document_version(ui_document_id, version DESC);  
  
CREATE INDEX idx_ui_document_version_visibility_created  
  ON core.ui_document_version(visibility, created_at DESC, ui_document_id);  
  
CREATE TABLE core.weight_preset (  
  weight_preset_id uuid PRIMARY KEY,  
  universe_id uuid NOT NULL,  
  owner_subject uuid NOT NULL,  
  forked_from_weight_preset_id uuid REFERENCES core.weight_preset(weight_preset_id),  
  created_at timestamptz NOT NULL DEFAULT now()  
);  
  
CREATE TABLE core.weight_preset_version (  
  weight_preset_version_id uuid PRIMARY KEY,  
  weight_preset_id uuid NOT NULL REFERENCES core.weight_preset(weight_preset_id),  
  version integer NOT NULL CHECK (version >= 1),  
  title text NOT NULL CHECK (char_length(title) BETWEEN 1 AND 200),  
  description text NOT NULL DEFAULT '' CHECK (char_length(description) <= 2000),  
  visibility text NOT NULL CHECK (visibility IN ('PRIVATE','PUBLIC')),  
  weight_schema_version integer NOT NULL CHECK (weight_schema_version = 1),  
  weight_json jsonb NOT NULL CHECK (jsonb_typeof(weight_json) = 'object'),  
  weight_hash text NOT NULL CHECK (weight_hash ~ '^[0-9a-f]{64}$'),  
  created_at timestamptz NOT NULL DEFAULT now(),  
  UNIQUE (weight_preset_id, version),  
  UNIQUE (weight_preset_id, weight_hash)  
);  
  
CREATE INDEX idx_weight_preset_owner_created  
  ON core.weight_preset(owner_subject, created_at DESC, weight_preset_id);  
  
CREATE INDEX idx_weight_preset_universe_created  
  ON core.weight_preset(universe_id, created_at DESC, weight_preset_id);  
  
CREATE INDEX idx_weight_preset_version_doc_version  
  ON core.weight_preset_version(weight_preset_id, version DESC);  
  
CREATE INDEX idx_weight_preset_version_visibility_created  
  ON core.weight_preset_version(visibility, created_at DESC, weight_preset_id);


-- =====================================================  
-- SEMANTIC  
-- =====================================================  
  
CREATE TABLE semantic.measurement_definition (  
  measurement_definition_id uuid PRIMARY KEY,  
  name text NOT NULL,  
  version integer NOT NULL,  
  created_at timestamptz NOT NULL DEFAULT now(),  
  UNIQUE(name, version)  
);  
  
CREATE TABLE semantic.measurement (  
  measurement_id uuid PRIMARY KEY,  
  entity_id uuid NOT NULL REFERENCES core.entity(entity_id),  
  measurement_definition_id uuid NOT NULL  
    REFERENCES semantic.measurement_definition(measurement_definition_id),  
  numeric_value numeric NOT NULL,  
  created_at timestamptz NOT NULL DEFAULT now()  
);  
  
CREATE INDEX idx_measurement_entity  
  ON semantic.measurement(entity_id);
-- =====================================================  
-- RAW  
-- =====================================================  
  
CREATE TABLE raw.raw_observation (  
  observation_id uuid PRIMARY KEY,  
  entity_id uuid NOT NULL REFERENCES core.entity(entity_id),  
  payload_json text NOT NULL,  
  recorded_at timestamptz NOT NULL,  
  created_at timestamptz NOT NULL DEFAULT now()  
);  



-- =====================================================  
-- MARKET  
-- =====================================================  
  
CREATE TABLE market.account (  
  account_id uuid PRIMARY KEY,  
  account_type text NOT NULL CHECK (  
    account_type IN ('asset','liability','equity','revenue','expense')  
  ),  
  allow_negative boolean NOT NULL DEFAULT false,  
  created_at timestamptz NOT NULL DEFAULT now()  
);
CREATE TABLE market.ledger_transaction (  
  transaction_id uuid PRIMARY KEY,  
  created_at timestamptz NOT NULL DEFAULT now(),  
  payload_hash text NOT NULL,  
  signature text NOT NULL,  
  signer_public_key text NOT NULL  
);  
  
CREATE TABLE market.ledger_entry (  
  ledger_entry_id uuid PRIMARY KEY,  
  transaction_id uuid NOT NULL  
    REFERENCES market.ledger_transaction(transaction_id),  
  account_id uuid NOT NULL  
    REFERENCES market.account(account_id),  
  debit numeric(18,2) NOT NULL DEFAULT 0 CHECK (debit >= 0),  
  credit numeric(18,2) NOT NULL DEFAULT 0 CHECK (credit >= 0),  
  created_at timestamptz NOT NULL DEFAULT now(),  
  CHECK (  
    (debit = 0 AND credit > 0) OR  
    (credit = 0 AND debit > 0)  
  )  
);
CREATE TABLE market.offer (  
  offer_id uuid PRIMARY KEY,  
  universe_id uuid NOT NULL,  
  entity_id uuid NOT NULL,  
  seller_entity_id uuid NOT NULL,  
  quantity integer NOT NULL,  
  price_per_unit numeric(18,2) NOT NULL,  
  status text NOT NULL DEFAULT 'open',  
  created_at timestamptz NOT NULL DEFAULT now(),  
  cancelled_at timestamptz  
);  
  
CREATE TABLE market.ownership (  
  ownership_id uuid PRIMARY KEY,  
  universe_id uuid NOT NULL,  
  entity_id uuid NOT NULL,  
  owner_entity_id uuid NOT NULL,  
  available_quantity integer NOT NULL CHECK (available_quantity >= 0),  
  reserved_quantity integer NOT NULL DEFAULT 0,  
  acquired_at timestamptz NOT NULL DEFAULT now(),  
  UNIQUE (universe_id, entity_id, owner_entity_id)  
);
CREATE TABLE market.ownership_history (  
  ownership_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),  
  universe_id uuid NOT NULL,  
  entity_id uuid NOT NULL,  
  owner_entity_id uuid NOT NULL,  
  delta numeric NOT NULL,  
  reason text NOT NULL,  
  created_at timestamptz NOT NULL DEFAULT now()  
);  
  
CREATE TABLE market.trade_execution (  
  trade_execution_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),  
  offer_id uuid NOT NULL,  
  buyer_entity_id uuid NOT NULL,  
  quantity integer NOT NULL,  
  idempotency_key text NOT NULL UNIQUE,  
  created_at timestamptz NOT NULL DEFAULT now()  
);  
  
CREATE TABLE market.trade_history (  
  trade_id uuid PRIMARY KEY,  
  offer_id uuid NOT NULL,  
  universe_id uuid NOT NULL,  
  entity_id uuid NOT NULL,  
  seller_entity_id uuid NOT NULL,  
  buyer_entity_id uuid NOT NULL,  
  quantity integer NOT NULL,  
  price_per_unit numeric NOT NULL,  
  executed_at timestamptz NOT NULL DEFAULT now()  
);
-- =====================================================  
-- IMMUTABLE / GUARD FUNCTIONS  
-- =====================================================  
  
CREATE OR REPLACE FUNCTION market.forbid_mutation()  
RETURNS trigger LANGUAGE plpgsql AS $$  
BEGIN  
  RAISE EXCEPTION 'This table is immutable';  
END;  
$$;  
  
CREATE OR REPLACE FUNCTION market.forbid_offer_update()  
RETURNS trigger LANGUAGE plpgsql AS $$  
BEGIN  
  RAISE EXCEPTION 'Offers are immutable';  
END;  
$$;  
  
CREATE OR REPLACE FUNCTION market.forbid_ledger_modification()  
RETURNS trigger LANGUAGE plpgsql AS $$  
BEGIN  
  RAISE EXCEPTION 'Ledger entries are immutable';  
END;  
$$;  
  
CREATE OR REPLACE FUNCTION universe.forbid_update()  
RETURNS trigger LANGUAGE plpgsql AS $$  
BEGIN  
  RAISE EXCEPTION 'Immutable table';  
END;  
$$;
-- =====================================================  
-- BALANCE / CONSISTENCY  
-- =====================================================  
  
CREATE OR REPLACE FUNCTION market.enforce_balance()  
RETURNS trigger LANGUAGE plpgsql AS $$  
DECLARE  
  total_debit numeric;  
  total_credit numeric;  
BEGIN  
  SELECT COALESCE(SUM(debit),0),  
         COALESCE(SUM(credit),0)  
  INTO total_debit,total_credit  
  FROM market.ledger_entry  
  WHERE transaction_id = NEW.transaction_id;  
  
  IF total_debit <> total_credit THEN  
    RAISE EXCEPTION 'Transaction not balanced';  
  END IF;  
  
  RETURN NULL;  
END;  
$$;  
  
CREATE OR REPLACE FUNCTION market.enforce_no_negative()  
RETURNS trigger LANGUAGE plpgsql AS $$  
DECLARE  
  acc record;  
  bal numeric;  
BEGIN  
  SELECT * INTO acc  
  FROM market.account  
  WHERE account_id = NEW.account_id;

IF acc.allow_negative = FALSE THEN  
    SELECT COALESCE(SUM(debit-credit),0)  
    INTO bal  
    FROM market.ledger_entry  
    WHERE account_id = NEW.account_id;  
  
    IF bal < 0 THEN  
      RAISE EXCEPTION 'Negative balance not allowed';  
    END IF;  
  END IF;  
  
  RETURN NULL;  
END;  
$$;  
  
CREATE OR REPLACE FUNCTION market.check_balance()  
RETURNS trigger LANGUAGE plpgsql AS $$  
DECLARE  
  current_balance numeric;  
BEGIN  
  SELECT COALESCE(SUM(delta),0)  
  INTO current_balance  
  FROM market.ownership_history  
  WHERE universe_id = NEW.universe_id  
    AND entity_id = NEW.entity_id  
    AND owner_entity_id = NEW.owner_entity_id;  
  
  IF (current_balance + NEW.delta) < 0 THEN  
    RAISE EXCEPTION 'Insufficient balance';  
  END IF;  
  
  RETURN NEW;  
END;  
$$;

-- =====================================================  
-- TRIGGERS  
-- =====================================================  
  
CREATE CONSTRAINT TRIGGER balance_check  
AFTER INSERT ON market.ledger_entry  
DEFERRABLE INITIALLY DEFERRED  
FOR EACH ROW  
EXECUTE FUNCTION market.enforce_balance();  
  
CREATE CONSTRAINT TRIGGER balance_non_negative  
AFTER INSERT ON market.ledger_entry  
DEFERRABLE INITIALLY DEFERRED  
FOR EACH ROW  
EXECUTE FUNCTION market.enforce_no_negative();  
  
CREATE TRIGGER no_update_ledger  
BEFORE UPDATE ON market.ledger_entry  
FOR EACH ROW EXECUTE FUNCTION market.forbid_mutation();  
  
CREATE TRIGGER no_delete_ledger  
BEFORE DELETE ON market.ledger_entry  
FOR EACH ROW EXECUTE FUNCTION market.forbid_mutation();  
  
CREATE TRIGGER no_update_offer  
BEFORE UPDATE ON market.offer  
FOR EACH ROW EXECUTE FUNCTION market.forbid_offer_update();

CREATE TRIGGER no_delete_offer  
BEFORE DELETE ON market.offer  
FOR EACH ROW EXECUTE FUNCTION market.forbid_offer_update();  
  
CREATE TRIGGER no_update_ownership_history  
BEFORE UPDATE ON market.ownership_history  
FOR EACH ROW EXECUTE FUNCTION market.forbid_mutation();  
  
CREATE TRIGGER no_delete_ownership_history  
BEFORE DELETE ON market.ownership_history  
FOR EACH ROW EXECUTE FUNCTION market.forbid_mutation();  
  
CREATE TRIGGER prevent_negative_balance  
BEFORE INSERT ON market.ownership_history  
FOR EACH ROW EXECUTE FUNCTION market.check_balance();  
  
CREATE TRIGGER no_update_snapshot  
BEFORE UPDATE OR DELETE ON universe.universe_snapshot  
FOR EACH ROW EXECUTE FUNCTION universe.forbid_update();

-- =====================================================  
-- FOREIGN KEYS NOT INLINED EARLIER  
-- =====================================================  
  
ALTER TABLE raw.raw_observation  
  ADD FOREIGN KEY (entity_id)  
  REFERENCES core.entity(entity_id);  
  
ALTER TABLE semantic.measurement  
  ADD FOREIGN KEY (entity_id)  
  REFERENCES core.entity(entity_id);  
  
ALTER TABLE derived.feature_value  
  ADD CONSTRAINT feature_value_entity_id_fkey  
  FOREIGN KEY (entity_id)  
  REFERENCES core.entity(entity_id);  

COMMIT;








