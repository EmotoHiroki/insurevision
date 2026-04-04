-- =============================================
-- W3 Schema Migration — G-1/G-2/G-3 + Suspension
-- =============================================

-- G-2: 顧客名
ALTER TABLE run ADD COLUMN IF NOT EXISTS customer_name text;

-- G-1: 意向確認相手
ALTER TABLE run ADD COLUMN IF NOT EXISTS intent_confirmed_with text;

-- G-3: 法人意思決定者
ALTER TABLE run ADD COLUMN IF NOT EXISTS corporate_decision_maker text;

-- Suspension flow
ALTER TABLE run ADD COLUMN IF NOT EXISTS pending_note       text;
ALTER TABLE run ADD COLUMN IF NOT EXISTS suspended_at       timestamptz;
ALTER TABLE run ADD COLUMN IF NOT EXISTS suspension_type    text
    CHECK (suspension_type IN ('condition_adjustment', 'mid_session'));

-- Extend run_status CHECK to include 'suspended'
ALTER TABLE run DROP CONSTRAINT IF EXISTS run_run_status_check;
ALTER TABLE run ADD CONSTRAINT run_run_status_check
    CHECK (run_status IN ('draft', 'finalized', 'archived', 'suspended'));
