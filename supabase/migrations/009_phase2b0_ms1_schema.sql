-- =============================================
-- Migration 009: Phase2-b-0 MS1 — 種目横断共通基盤スキーマ（修正版）
-- =============================================
-- 変更点（初版からの修正）:
--   5上位分類（insurance_category）と実種目（insurance_line）を分離した3層構造に変更。
--   category_code: auto / property / liability / person / profit_expense
--   line_code    : auto / fire（b0-MS1シード）、その他は b-1〜b-4 で逐次投入
--
-- 目的:
--   Phase2-a（自動車保険）で構築したフローを「どの種目でも使える共通基盤」へ拡張する
--   ためのデータモデル・マスタ・設計判断を定義する。
--
-- 本マイグレーションは b0-MS1（設計・スキーマ確定フェーズ）の成果物です。
--   - 5上位分類マスタ（insurance_category）
--   - 種目マスタ（insurance_line）— auto/fire のみシード
--   - 3つの契約フロー種別（完全新規 / 新規-既存顧客 / 継続更改）
--   - 診断基点の切替（現契約との差分 / あるべき補償像との差分）
--   - 対象物件プロファイル（line_code 単位で種目別に保持する JSONB 構造）
--   - 補償ルールマスタ（line_code キー。スキーマのみ。実データは b-1 火災で投入）
--   - 水災等地マスタ（スキーマのみ。実データは b-1 火災で投入）
--   - 意向確認構造（推定意向 / 最終意向 / 合致確認 / 補償重複）
--   - audit_event の種目横断名前空間（line_code ベース: fire.* / auto.* 等）
--   - 案件フェーズ（準備済 / 面談中 / 完了）= ダッシュボード基盤
--
-- 対象外（b-1 火災以降）:
--   火災固有の補償ルール実データ、等地実データ、火災診断ロジック、火災固有画面、
--   機械・動産総合・医療・所得補償等の新種目、企業分野火災、CRM/外部API連携。
--
-- すべて冪等（IF NOT EXISTS / DROP ... IF EXISTS）で、既存本番DBにも
-- まっさらなDBにも安全に適用できます。
-- =============================================

-- ── 1. 5上位分類マスタ（insurance_category） ──────────────────────────────────
-- 安心見える化 の上位5分類。
--   auto:           自動車（Phase2-a で実装済み）
--   property:       モノ（財物）配下に火災・機械・動産総合等の種目を収容
--   liability:      賠償責任（b-2 以降で種目を逐次追加）
--   person:         ヒト（b-3 以降：傷害・医療・所得補償等）
--   profit_expense: 利益費用（b-4 以降。法人専用）
CREATE TABLE IF NOT EXISTS insurance_category (
    code               text PRIMARY KEY
                         CHECK (code IN ('auto', 'property', 'liability', 'person', 'profit_expense')),
    label_ja           text NOT NULL,
    label_en           text NOT NULL,
    supports_individual boolean NOT NULL DEFAULT true,
    supports_corporate  boolean NOT NULL DEFAULT true,
    is_active          boolean NOT NULL DEFAULT true,
    sort_order         integer NOT NULL DEFAULT 0,
    created_at         timestamptz NOT NULL DEFAULT now(),
    updated_at         timestamptz NOT NULL DEFAULT now()
);

INSERT INTO insurance_category
    (code, label_ja, label_en, supports_individual, supports_corporate, sort_order)
VALUES
    ('auto',           '自動車',       'Auto',             true,  true,  1),
    ('property',       'モノ（財物）', 'Property',         true,  true,  2),
    ('liability',      '賠償責任',     'Liability',        true,  true,  3),
    ('person',         'ヒト',         'Person',           true,  true,  4),
    ('profit_expense', '利益・費用',    'Profit & Expense', false, true,  5)
ON CONFLICT (code) DO UPDATE SET
    label_ja            = EXCLUDED.label_ja,
    label_en            = EXCLUDED.label_en,
    supports_individual = EXCLUDED.supports_individual,
    supports_corporate  = EXCLUDED.supports_corporate,
    sort_order          = EXCLUDED.sort_order,
    updated_at          = now();

ALTER TABLE insurance_category ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS insurance_category_public_read ON insurance_category;
CREATE POLICY insurance_category_public_read ON insurance_category
    FOR SELECT USING (true);

-- ── 2. 種目マスタ（insurance_line） ──────────────────────────────────────────
-- 各上位分類配下の実際の保険種目。
--   property 配下:  fire（火災）、machine（機械）、movable_property（動産総合）等 b-1 以降
--   auto 配下:      auto（自動車は分類=種目が一致）
--   liability 配下: liability（賠償責任）
--   person 配下:    accident（傷害）、medical（医療）等 b-3 以降
--
-- b0-MS1 では auto と fire の2行のみシード。その他は後続フェーズで投入。
--
-- UNIQUE(code, category_code) は run テーブルからの複合 FK で参照し、
-- line_code と category_code の不整合を DB レベルで防ぐための制約。
CREATE TABLE IF NOT EXISTS insurance_line (
    code               text PRIMARY KEY,
    category_code      text NOT NULL REFERENCES insurance_category(code),
    label_ja           text NOT NULL,
    label_en           text NOT NULL,
    milestone          text NOT NULL DEFAULT '',
    supports_individual boolean NOT NULL DEFAULT true,
    supports_corporate  boolean NOT NULL DEFAULT true,
    is_implemented     boolean NOT NULL DEFAULT false,
    is_active          boolean NOT NULL DEFAULT true,
    sort_order         integer NOT NULL DEFAULT 0,
    created_at         timestamptz NOT NULL DEFAULT now(),
    updated_at         timestamptz NOT NULL DEFAULT now()
);

-- 複合ユニーク制約: run からの複合 FK で line と category の整合を DB レベルで保証する
DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM pg_constraint
        WHERE conname = 'insurance_line_code_category_unique'
    ) THEN
        ALTER TABLE insurance_line
          ADD CONSTRAINT insurance_line_code_category_unique
            UNIQUE (code, category_code);
    END IF;
END$$;

INSERT INTO insurance_line
    (code, category_code, label_ja, label_en, milestone, supports_individual, supports_corporate, is_implemented, sort_order)
VALUES
    ('auto', 'auto',     '自動車', 'Auto', 'Phase2-a', true, true, true,  1),
    ('fire', 'property', '火災',   'Fire', 'b-1',      true, true, false, 1)
ON CONFLICT (code) DO UPDATE SET
    category_code       = EXCLUDED.category_code,
    label_ja            = EXCLUDED.label_ja,
    label_en            = EXCLUDED.label_en,
    milestone           = EXCLUDED.milestone,
    supports_individual = EXCLUDED.supports_individual,
    supports_corporate  = EXCLUDED.supports_corporate,
    sort_order          = EXCLUDED.sort_order,
    updated_at          = now();

CREATE INDEX IF NOT EXISTS idx_insurance_line_category ON insurance_line(category_code);

ALTER TABLE insurance_line ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS insurance_line_public_read ON insurance_line;
CREATE POLICY insurance_line_public_read ON insurance_line
    FOR SELECT USING (true);

-- ── 3. run 拡張：種目・契約フロー・診断基点・案件フェーズ ──────────────────
ALTER TABLE run
  ADD COLUMN IF NOT EXISTS insurance_category_code text
    REFERENCES insurance_category(code);

ALTER TABLE run
  ADD COLUMN IF NOT EXISTS insurance_line_code text
    REFERENCES insurance_line(code);

-- 複合 FK: insurance_line_code と insurance_category_code の整合を DB レベルで保証。
-- line_code が決まれば category_code は insurance_line から一意に定まる。
-- これにより「line=fire, category=person」のような不整合を DB が拒否する。
ALTER TABLE run
  DROP CONSTRAINT IF EXISTS run_line_category_fk;

ALTER TABLE run
  ADD CONSTRAINT run_line_category_fk
    FOREIGN KEY (insurance_line_code, insurance_category_code)
    REFERENCES insurance_line(code, category_code);

ALTER TABLE run
  ADD COLUMN IF NOT EXISTS contract_flow_type text
    CHECK (contract_flow_type IN ('new_complete', 'new_existing', 'renewal'));

ALTER TABLE run
  ADD COLUMN IF NOT EXISTS diagnosis_baseline text
    CHECK (diagnosis_baseline IN ('contract_diff', 'ideal_coverage_diff'));

ALTER TABLE run
  ADD COLUMN IF NOT EXISTS case_phase text NOT NULL DEFAULT 'preparing'
    CHECK (case_phase IN ('preparing', 'in_meeting', 'completed'));

-- 後埋め: 既存自動車案件（product_line='auto' または空・NULL）
-- category_code=auto / line_code=auto で揃える（複合 FK に適合）
UPDATE run
   SET insurance_category_code = 'auto',
       insurance_line_code     = 'auto'
 WHERE insurance_category_code IS NULL
   AND (product_line = 'auto' OR product_line = '' OR product_line IS NULL);

-- 自動車以外の run が存在した場合: category/line は NULL のまま（未分類）とし、
-- 適用後に個別対応する。適用前に以下 SQL で確認すること:
--   SELECT product_line, run_type, COUNT(*) FROM run GROUP BY 1, 2;

-- 契約フロー後埋め（NULL のみ）
UPDATE run
   SET contract_flow_type = CASE
         WHEN run_type = 'renewal' THEN 'renewal'
         ELSE 'new_existing'
       END
 WHERE contract_flow_type IS NULL;

-- 診断基点後埋め（NULL のみ）
UPDATE run
   SET diagnosis_baseline = CASE
         WHEN contract_flow_type = 'new_complete' THEN 'ideal_coverage_diff'
         ELSE 'contract_diff'
       END
 WHERE diagnosis_baseline IS NULL;

CREATE INDEX IF NOT EXISTS idx_run_insurance_category ON run(insurance_category_code);
CREATE INDEX IF NOT EXISTS idx_run_insurance_line     ON run(insurance_line_code);
CREATE INDEX IF NOT EXISTS idx_run_case_phase         ON run(case_phase);

-- ── 4. 対象物件プロファイル（property_profile） ───────────────────────────
-- category_code ではなく line_code をキーにする。
-- UNIQUE(run_id, line_code) により、同一 run 内で火災・機械など複数の種目を
-- 並行して持てる（将来 property 配下の複数種目対応が可能）。
-- 上位分類（category）は line_code から insurance_line を JOIN して取得する。
CREATE TABLE IF NOT EXISTS property_profile (
    id                 uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    run_id             uuid NOT NULL REFERENCES run(id) ON DELETE CASCADE,
    line_code          text NOT NULL REFERENCES insurance_line(code),
    municipality_code  text,
    attributes         jsonb NOT NULL DEFAULT '{}',
    created_at         timestamptz NOT NULL DEFAULT now(),
    updated_at         timestamptz NOT NULL DEFAULT now(),
    UNIQUE (run_id, line_code)
);

CREATE INDEX IF NOT EXISTS idx_property_profile_run_id ON property_profile(run_id);

ALTER TABLE property_profile ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS property_profile_own_agency ON property_profile;
CREATE POLICY property_profile_own_agency ON property_profile
    USING (
        run_id IN (
            SELECT id FROM run WHERE agency_id = get_my_agency_id()
        )
    );

-- ── 5. 補償ルールマスタ（coverage_rule_master）スキーマのみ ────────────────
-- 「あるべき補償像」算出の核。line_code x 補償項目 x 条件 -> 3段階ティア。
-- category_code ではなく line_code でキー付けすることで、同じ property 配下の
-- 火災ルールと機械ルールを明確に分離できる（FIRE_BASIC_* vs MACH_BASIC_*）。
-- 実データ（火災の補償項目・条件）は b-1 火災で投入。
CREATE TABLE IF NOT EXISTS coverage_rule_master (
    id                 uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    line_code          text NOT NULL REFERENCES insurance_line(code),
    coverage_code      text NOT NULL,
    coverage_label_ja  text NOT NULL,
    condition          jsonb NOT NULL DEFAULT '{}',
    tier               text NOT NULL
                         CHECK (tier IN ('standard_required', 'needs_check', 'optional_excluded')),
    intent_dependent   boolean NOT NULL DEFAULT false,
    note               text,
    sort_order         integer NOT NULL DEFAULT 0,
    is_active          boolean NOT NULL DEFAULT true,
    created_at         timestamptz NOT NULL DEFAULT now(),
    updated_at         timestamptz NOT NULL DEFAULT now(),
    UNIQUE (line_code, coverage_code, tier)
);

CREATE INDEX IF NOT EXISTS idx_coverage_rule_line ON coverage_rule_master(line_code);

ALTER TABLE coverage_rule_master ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS coverage_rule_master_public_read ON coverage_rule_master;
CREATE POLICY coverage_rule_master_public_read ON coverage_rule_master
    FOR SELECT USING (true);

-- ── 6. 水災等地マスタ（flood_zone_master）スキーマのみ ─────────────────────
CREATE TABLE IF NOT EXISTS flood_zone_master (
    municipality_code  text PRIMARY KEY,
    prefecture         text NOT NULL,
    municipality_name  text NOT NULL,
    flood_grade        integer NOT NULL
                         CHECK (flood_grade BETWEEN 1 AND 5),
    source             text NOT NULL DEFAULT '損害保険料率算出機構',
    effective_from     date,
    created_at         timestamptz NOT NULL DEFAULT now(),
    updated_at         timestamptz NOT NULL DEFAULT now()
);

ALTER TABLE flood_zone_master ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS flood_zone_master_public_read ON flood_zone_master;
CREATE POLICY flood_zone_master_public_read ON flood_zone_master
    FOR SELECT USING (true);

-- ── 7. 意向確認構造（intent_confirmation） ────────────────────────────────
-- 完全新規（new_complete）で必須。監督指針 II-4-2-2(3) 意向の把握・確認義務。
CREATE TABLE IF NOT EXISTS intent_confirmation (
    id                 uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    run_id             uuid NOT NULL REFERENCES run(id) ON DELETE CASCADE,
    inferred_intent    jsonb NOT NULL DEFAULT '{}',
    final_intent       jsonb NOT NULL DEFAULT '{}',
    match_confirmed    boolean,
    discrepancy_note   text,
    overlap_check      jsonb NOT NULL DEFAULT '{}',
    regulatory_basis   text NOT NULL DEFAULT '監督指針 II-4-2-2(3)',
    confirmed_at       timestamptz,
    confirmed_by       uuid REFERENCES operator(id),
    created_at         timestamptz NOT NULL DEFAULT now(),
    updated_at         timestamptz NOT NULL DEFAULT now(),
    UNIQUE (run_id)
);

CREATE INDEX IF NOT EXISTS idx_intent_confirmation_run_id ON intent_confirmation(run_id);

ALTER TABLE intent_confirmation ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS intent_confirmation_own_agency ON intent_confirmation;
CREATE POLICY intent_confirmation_own_agency ON intent_confirmation
    USING (
        run_id IN (
            SELECT id FROM run WHERE agency_id = get_my_agency_id()
        )
    );

-- ── 8. audit_event 種目横断名前空間の拡張 ─────────────────────────────────
-- 種目固有イベントは line_code を接頭辞とした名前空間を使う（例: fire.*）。
-- category_code ではなく line_code ベースにすることで、同じ property 配下の
-- 火災・機械ルールを名前空間で明確に分離できる（fire.* vs machine.*）。
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
    'important_matters_delivery_confirmed',
    -- MS3 report (+4)
    'recommended_plan_set',
    'decided_plan_set',
    'plan_diff_reason_recorded',
    'agency_report_generated',
    -- Phase2-b-0 種目横断共通 (+9)
    'insurance_category_selected',    -- 上位5分類の選択
    'insurance_line_selected',         -- 実種目（fire 等）の選択
    'contract_flow_selected',          -- 契約フロー種別選択
    'case_phase_changed',              -- 案件フェーズ遷移
    'property_profile_recorded',       -- 対象物件プロファイル記録
    'ideal_coverage_diagnosed',        -- あるべき補償像との差分診断
    'intent_inferred',                 -- 推定意向の確定
    'intent_finalized',                -- 最終意向の確定・合致確認
    'coverage_overlap_checked'         -- 補償重複の確認
  ));

-- =============================================
-- 適用後の整合性メモ:
--   - insurance_category: 5行（auto/property/liability/person/profit_expense）
--   - insurance_line: 2行（auto/fire）。fire.is_implemented=false（b-1で true 化）
--   - run: insurance_category_code + insurance_line_code を複合 FK で保護
--   - 既存自動車案件: category_code='auto' / line_code='auto' で後埋め済み
--   - coverage_rule_master / flood_zone_master は空（実データは b-1）
-- =============================================
