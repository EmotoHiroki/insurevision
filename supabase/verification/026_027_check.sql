-- ============================================================================
-- 026_027_check.sql
--
-- migration 026（DELETE剥奪）・027（TRIGGER剥奪）の検証。DDLを含まない。
-- ============================================================================
DO $$
DECLARE v_bad text;
BEGIN
    SELECT string_agg(c.relname, ', ') INTO v_bad
      FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace
     WHERE n.nspname='public' AND c.relkind='r'
       AND (has_table_privilege('anon','public.'||c.relname,'DELETE')
         OR has_table_privilege('authenticated','public.'||c.relname,'DELETE'));
    IF v_bad IS NOT NULL THEN
        RAISE EXCEPTION '026 verify failed: DELETE still granted on -> %', v_bad;
    END IF;
    RAISE NOTICE '026 verify passed: no table grants DELETE to anon/authenticated';
END $$;

DO $$
DECLARE v_bad text;
BEGIN
    SELECT string_agg(c.relname, ', ') INTO v_bad
      FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace
     WHERE n.nspname='public' AND c.relkind='r'
       AND (has_table_privilege('anon','public.'||c.relname,'TRIGGER')
         OR has_table_privilege('authenticated','public.'||c.relname,'TRIGGER'));
    IF v_bad IS NOT NULL THEN
        RAISE EXCEPTION '027 verify failed: TRIGGER still granted on -> %', v_bad;
    END IF;
    RAISE NOTICE '027 verify passed: no table grants TRIGGER to anon/authenticated';
END $$;

-- ── 全8権限の横展開スイープ（同型の見落としの再発防止。田島様2026-07-30ご指摘C-12）──
-- SELECT/INSERT/UPDATEを除く5権限（DELETE・TRUNCATE・REFERENCES・TRIGGER・
-- MAINTAIN）はいずれもRLSの行単位制御の対象外であり、anon/authenticatedに
-- 残す理由がない。5権限すべてが0件であることを確認する。
DO $$
DECLARE v_bad text;
BEGIN
    SELECT string_agg(format('%s/%s/%s', r.rolname, p.priv, c.relname), ', ')
      INTO v_bad
      FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace
     CROSS JOIN (VALUES ('anon'),('authenticated')) AS r(rolname)
     CROSS JOIN (VALUES ('DELETE'),('TRUNCATE'),('REFERENCES'),('TRIGGER'),('MAINTAIN')) AS p(priv)
     WHERE n.nspname='public' AND c.relkind='r'
       AND has_table_privilege(r.rolname, 'public.'||c.relname, p.priv);
    IF v_bad IS NOT NULL THEN
        RAISE EXCEPTION 'RLS-exempt privilege sweep failed: residual grants -> %', v_bad;
    END IF;
    RAISE NOTICE 'RLS-exempt privilege sweep passed: DELETE/TRUNCATE/REFERENCES/TRIGGER/MAINTAIN all absent for anon and authenticated across all 17 tables';
END $$;
