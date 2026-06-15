-- =============================================
-- Migration 008: Phase2-a Retroactive Tables (MS4)
-- =============================================
-- These tables exist on the production DB but had no migration file in
-- supabase/migrations/. This migration backfills them so the migration set
-- reproduces the production schema (MS4: DBスキーマ・マイグレーション確定版).
--
-- Phase2-a で使用中:
--   - smartphone_confirm_token  (MS2 スマホ確認トークン)
--   - agency_config             (代理店名・署名ポリシー / 帳票の代理店名解決元)
-- 前方互換のためDB上に存在（Phase2-a app未参照・将来利用）:
--   - agency_rule_override, restriction_reason_master, run_participant
--
-- All statements are idempotent (IF NOT EXISTS / DROP POLICY IF EXISTS) so this
-- migration is safe to run against the existing production DB and a fresh DB alike.
-- =============================================

-- ── helper: get_my_agency_id() (used by RLS policies below) ──────────────────
CREATE OR REPLACE FUNCTION public.get_my_agency_id()
  RETURNS uuid
  LANGUAGE sql
  STABLE SECURITY DEFINER
  SET search_path TO 'public'
AS $function$
  SELECT agency_id FROM operator WHERE auth_user_id = auth.uid() LIMIT 1;
$function$;

-- ── agency_config (代理店名・署名ポリシー) ──────────────────────────────────
CREATE TABLE IF NOT EXISTS agency_config (
    id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    agency_id        uuid NOT NULL UNIQUE,
    agency_name      text NOT NULL,
    signature_policy text NOT NULL DEFAULT 'none'
                       CHECK (signature_policy IN ('none', 'optional', 'required')),
    created_at       timestamptz NOT NULL DEFAULT now(),
    updated_at       timestamptz NOT NULL DEFAULT now()
);

ALTER TABLE agency_config ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS agency_config_select_own ON agency_config;
CREATE POLICY agency_config_select_own ON agency_config
    FOR SELECT USING (agency_id = get_my_agency_id());

-- ── agency_rule_override (代理店別ルール上書き) ─────────────────────────────
CREATE TABLE IF NOT EXISTS agency_rule_override (
    id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    agency_id   uuid NOT NULL REFERENCES agency_config(agency_id),
    rule_code   text NOT NULL,
    is_enabled  boolean NOT NULL DEFAULT true,
    severity    text CHECK (severity IN ('block', 'warn', 'info')),
    created_at  timestamptz NOT NULL DEFAULT now(),
    updated_at  timestamptz NOT NULL DEFAULT now(),
    UNIQUE (agency_id, rule_code)
);

ALTER TABLE agency_rule_override ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS agency_rule_override_select_own ON agency_rule_override;
CREATE POLICY agency_rule_override_select_own ON agency_rule_override
    FOR SELECT USING (agency_id = get_my_agency_id());

-- ── restriction_reason_master (除外理由マスタ) ──────────────────────────────
CREATE TABLE IF NOT EXISTS restriction_reason_master (
    code       text PRIMARY KEY,
    label      text NOT NULL,
    is_active  boolean NOT NULL DEFAULT true,
    sort_order integer NOT NULL
);

ALTER TABLE restriction_reason_master ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS restriction_reason_master_public_read ON restriction_reason_master;
CREATE POLICY restriction_reason_master_public_read ON restriction_reason_master
    FOR SELECT USING (true);

-- ── run_participant (案件参加者 / 複数募集人運用の基盤) ─────────────────────
-- RLS enabled with no policy on production (deny-by-default for client roles;
-- access via service role only). Matched here intentionally.
CREATE TABLE IF NOT EXISTS run_participant (
    id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    run_id      uuid NOT NULL,
    operator_id uuid NOT NULL,
    role        text NOT NULL CHECK (role IN ('primary', 'co', 'reviewer')),
    joined_at   timestamptz NOT NULL DEFAULT now(),
    UNIQUE (run_id, operator_id, role)
);

ALTER TABLE run_participant ENABLE ROW LEVEL SECURITY;

-- ── smartphone_confirm_token (MS2 スマホ確認トークン) ──────────────────────
-- RLS is intentionally DISABLED on production. Access control is enforced at the
-- API layer: the token is an unguessable UUID and the public endpoint returns
-- run:null for used/expired tokens (no customer info leak). Matched here.
CREATE TABLE IF NOT EXISTS smartphone_confirm_token (
    id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    run_id      uuid NOT NULL REFERENCES run(id) ON DELETE CASCADE,
    role        text NOT NULL CHECK (role IN ('recruiter', 'customer')),
    expires_at  timestamptz NOT NULL DEFAULT (now() + interval '30 minutes'),
    used_at     timestamptz,
    created_at  timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_sct_run_id ON smartphone_confirm_token(run_id);
CREATE INDEX IF NOT EXISTS idx_sct_id_role ON smartphone_confirm_token(id, role) WHERE used_at IS NULL;
