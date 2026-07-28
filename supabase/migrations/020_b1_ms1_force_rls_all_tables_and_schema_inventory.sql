-- ============================================================================
-- 020_b1_ms1_force_rls_all_tables_and_schema_inventory.sql
--
-- 状態: 本番適用済み（本ファイル作成と同一セッションで適用・実測）
--
-- 背景（田島様2026-07-27 23:41ご指摘3への対応）:
--
--   ご指摘のとおり、016で smartphone_confirm_token にのみ FORCE ROW LEVEL
--   SECURITY を付与した論理（将来所有者がBYPASSRLSを持たないロールへ変更
--   された場合の多層防御）は、他の16テーブルにも同様に当てはまる。
--
--   本migrationで全17テーブルに FORCE ROW LEVEL SECURITY を付与した。
--   016と同様、現時点では実効的な保護を追加するものではない（所有者
--   postgres は rolbypassrls=true を持つため、FORCEの有無にかかわらず
--   RLSを迂回する）。将来、所有者がBYPASSRLSを持たないロールへ変更された
--   場合に備える多層防御である。
--
--   あわせて、public スキーマの無条件走査により以下を確認した（実測）。
--     ビュー（relkind='v'）        : 0件
--     マテリアライズドビュー（'m'） : 0件
--     シーケンス（'S'）             : 0件
--     外部テーブル（'f'）           : 0件
--     パーティションテーブル（'p'） : 0件
--     通常テーブル（'r'）           : 17件
--     関数（pg_proc、無条件走査）   : 8件
--
--   ご指摘のとおり、ビューは既定でsecurity_invokerがfalseであり、所有者権限で
--   下層テーブルへアクセスするため、RLSを是正してもビュー経由の迂回経路が
--   残り得るという懸念は一般論として正しい。しかし本番には現時点でビュー・
--   マテリアライズドビューが1件も存在しないため、この経路は現状該当しない。
--   将来ビューを作成する場合は、security_invoker=true を既定とする運用を
--   徹底する必要がある（§既定権限の対応と合わせて検討）。
--
--   テーブル件数「17件」は、前回資料まではpg_policies等からの積み上げで
--   示していたが、本migrationのコメントに記載の値は pg_class を
--   schema='public' で無条件に走査した結果である。
--
-- スキーマレベル権限（実測。has_schema_privilege）:
--   anon           : USAGE=true, CREATE=false
--   authenticated  : USAGE=true, CREATE=false
--   PUBLIC         : USAGE=true, CREATE=false
--   CREATEがいずれのロールにも付与されていないため、anon・authenticatedが
--   publicスキーマに新規オブジェクトを作成することはできない。USAGEは
--   スキーマ内オブジェクトを参照するために必要な最小権限であり、それ自体は
--   リスクではない。
-- ============================================================================

DO $$
DECLARE t text;
BEGIN
    FOREACH t IN ARRAY ARRAY[
        'agency_config','agency_rule_override','audit_event','candidate','coverage_rule_master',
        'csv_import_session','flood_zone_master','insurance_category','insurance_line',
        'intent_confirmation','operator','property_profile','restriction_reason_master',
        'run','run_participant','snapshot'
    ] LOOP
        EXECUTE format('ALTER TABLE public.%I FORCE ROW LEVEL SECURITY', t);
    END LOOP;
END;
$$;

-- ── 自己検査 ────────────────────────────────────────────────────────────
DO $$
DECLARE
    v_missing integer;
BEGIN
    SELECT count(*) INTO v_missing
      FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace
     WHERE n.nspname='public' AND c.relkind='r' AND NOT c.relforcerowsecurity;
    IF v_missing <> 0 THEN
        RAISE EXCEPTION '020 self-check failed: % table(s) still missing FORCE ROW LEVEL SECURITY', v_missing;
    END IF;
    RAISE NOTICE '020 self-check passed: all 17 tables have FORCE ROW LEVEL SECURITY';
END;
$$;
