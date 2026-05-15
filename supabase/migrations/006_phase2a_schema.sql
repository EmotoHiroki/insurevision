-- =============================================
-- Migration 006: Phase2-a Schema
-- G-27: Electronic Consent Gate
-- G-28: Meeting Scene Preset (5 types)
-- Smartphone / Paper Confirmation Flow
-- Important Matters Delivery Confirmation
-- CSV Import Session Skeleton
-- =============================================

-- ── G-28: Meeting Scene Preset ────────────────────────────────────────────
-- Determines confirmation method, smartphone use, recruiter input mode
ALTER TABLE run
  ADD COLUMN meeting_scene VARCHAR(20)
    CHECK (meeting_scene IN (
      'visit_smartphone',  -- 訪問・スマホ連携
      'visit_paper',       -- 訪問・ペーパー確認
      'pc_tablet',         -- PC・タブレット型
      'telephone',         -- 電話募集型
      'web_meeting'        -- WEB面談
    ));

-- ── G-27: Electronic Consent (電子的方法による提供への同意確認) ────────────
ALTER TABLE run
  ADD COLUMN electronic_consent_status VARCHAR(20)
    CHECK (electronic_consent_status IN (
      'agreed',          -- 同意あり
      'declined',        -- 同意なし → 紙面確認モードへ
      'face_confirmed',  -- 面談時確認（対面での口頭確認）
      'not_recorded'     -- 未記録（電話募集等）
    )),
  ADD COLUMN electronic_consent_method VARCHAR(20)
    CHECK (electronic_consent_method IN (
      'email',       -- メール送付
      'url_share',   -- URL共有
      'qr_code',     -- QRコード
      'face_to_face' -- 対面確認
    )),
  ADD COLUMN electronic_consent_confirmed_at TIMESTAMPTZ,
  ADD COLUMN electronic_consent_operator_id UUID REFERENCES operator(id);

-- ── Smartphone Confirmation Flow ──────────────────────────────────────────
ALTER TABLE run
  ADD COLUMN smartphone_conf_status VARCHAR(20) DEFAULT 'not_required'
    CHECK (smartphone_conf_status IN (
      'not_required',       -- 紙面確認モード or 対象外シーン
      'pending',            -- PC側から確認リンク発行済み・未完了
      'recruiter_confirmed', -- 募集人スマホ確認完了
      'customer_confirmed',  -- お客様スマホ確認完了
      'paper_fallback'      -- スマホ利用困難 → 紙面切替済み
    )),
  ADD COLUMN recruiter_smartphone_confirmed_at TIMESTAMPTZ,
  ADD COLUMN customer_smartphone_confirmed_at TIMESTAMPTZ;

-- ── Paper Confirmation (紙面確認モード) ──────────────────────────────────
ALTER TABLE run
  ADD COLUMN paper_confirmation_status VARCHAR(20) DEFAULT 'not_required'
    CHECK (paper_confirmation_status IN (
      'not_required', -- スマホ確認モード使用
      'pending',      -- 紙面確認が必要な状態
      'completed'     -- 募集人が代理入力・確認完了
    )),
  ADD COLUMN paper_confirmation_completed_at TIMESTAMPTZ;

-- ── Important Matters Delivery Confirmation (重要事項説明書交付確認) ─────
ALTER TABLE run
  ADD COLUMN important_matters_delivered BOOLEAN NOT NULL DEFAULT FALSE,
  ADD COLUMN important_matters_delivered_at TIMESTAMPTZ,
  ADD COLUMN important_matters_delivery_method VARCHAR(20)
    CHECK (important_matters_delivery_method IN (
      'electronic', -- 電子交付（同意あり）
      'paper'       -- 書面交付（同意なし・紙面確認）
    ));

-- ── canNext Control State ─────────────────────────────────────────────────
-- Tracks why progression is blocked (for UI warnings + audit)
ALTER TABLE run
  ADD COLUMN can_next_blocked_reasons TEXT[] DEFAULT '{}';

-- ── Extend audit_event.event_type CHECK ──────────────────────────────────
ALTER TABLE audit_event
  DROP CONSTRAINT IF EXISTS audit_event_event_type_check;

ALTER TABLE audit_event
  ADD CONSTRAINT audit_event_event_type_check
  CHECK (event_type IN (
    -- M1 (11)
    'issue_shared',
    'manual_review_completed',
    'insurer_list_presented',
    'customer_intent_confirmed',
    'compare_presented',
    'exclusion_reason_recorded',
    'comparison_waiver_confirmed',
    'consent_important_matters',
    'consent_personal_info',
    'consent_comparison_result',
    'run_finalized',
    -- M2 (+2)
    'delivery_recorded',
    'redundancy_resolution_recorded',
    -- M3 (+5)
    'recording_mode_selected',
    'post_record_phase1_completed',
    'post_record_phase2_completed',
    'agent_input_mode_activated',
    'exclusion_reason_coded',
    -- Phase2-a (+6)
    'meeting_scene_selected',
    'electronic_consent_recorded',
    'recruiter_smartphone_confirmed',
    'customer_smartphone_confirmed',
    'paper_confirmation_completed',
    'important_matters_delivery_confirmed'
  ));

-- ── CSV Import Session Skeleton (MS3 implementation placeholder) ──────────
CREATE TABLE csv_import_session (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  run_id UUID REFERENCES run(id),
  session_status VARCHAR(20) NOT NULL DEFAULT 'pending'
    CHECK (session_status IN (
      'pending',     -- 取込開始前
      'previewing',  -- プレビュー表示中
      'confirmed',   -- 確定（取込完了）
      'cancelled',   -- キャンセル
      'error'        -- エラー
    )),
  filename TEXT,
  row_count INTEGER,
  mapped_fields JSONB DEFAULT '{}',       -- { csv_col: run_field }
  unmapped_fields TEXT[] DEFAULT '{}',    -- CSV columns without mapping
  manual_override_fields TEXT[] DEFAULT '{}', -- fields overridden by operator
  prior_contract_fields JSONB DEFAULT '{}',   -- 前回契約データ分離
  new_contract_fields JSONB DEFAULT '{}',     -- 今回契約データ分離
  error_detail TEXT,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  created_by UUID REFERENCES operator(id)
);

-- Index for CSV sessions per run
CREATE INDEX idx_csv_import_session_run_id ON csv_import_session(run_id);

-- RLS: Agency-scoped (same pattern as run table)
ALTER TABLE csv_import_session ENABLE ROW LEVEL SECURITY;

CREATE POLICY csv_import_session_agency_policy ON csv_import_session
  FOR ALL
  USING (
    run_id IN (
      SELECT r.id FROM run r
      JOIN operator op ON r.agency_id = op.agency_id
      WHERE op.auth_user_id = auth.uid()
    )
  );
