-- ============================================================================
-- 026_b1_ms1_revoke_unused_delete_privilege.sql
--
-- 状態: 本番適用済み
--
-- 背景（田島様2026-07-30ご指摘B-1への対応）:
--   024でcandidate/snapshotの直接UPDATEを剥奪したが、DELETEは対象にしていな
--   かった。実測の結果、以下のとおり判明した（田島様のご指摘より広範囲）。
--
--   GRANT実効権限（has_table_privilege による実測。REVOKE前）:
--     authenticated が DELETE を保持: 16/17テーブル
--       （smartphone_confirm_token のみ016で全剥奪済み・保持なし）
--     anon が DELETE を保持: 12/17テーブル
--       （audit_event・operator・property_profile・run・smartphone_confirm_token
--         の5件は保持なし）
--
--   RLSポリシーが実際にDELETEを通す状態にあるテーブル（cmd='ALL'のポリシーを
--   持つ5件。他12件はDELETEに対応するポリシーが0件のため、GRANTが残っていても
--   RLSのdeny-allにより現状は実害がない）:
--     candidate               (candidate_own_agency, FOR ALL)
--     csv_import_session      (csv_import_session_own_agency, FOR ALL。025で新設)
--     intent_confirmation     (intent_confirmation_own_agency, FOR ALL)
--     property_profile        (property_profile_own_agency, FOR ALL)
--     snapshot                (snapshot_own_agency, FOR ALL)
--
--   このうちcandidateは、024で追加した exclude_candidate による「除外」処理が
--   audit_event（exclusion_reason_recorded等）を残す設計だが、同一代理店の
--   active operatorがDELETEで直接削除すれば、その痕跡そのものが失われる。
--   snapshot・property_profile・intent_confirmation も同様に、確定条件・
--   意向確認・診断結果を保持するレコードであり、削除ではなく更新でのみ
--   状態遷移すべき対象である。
--
--   アプリコード（src/）を無条件走査した結果、`.delete(` の呼出しは
--   0件であることを確認した。DELETEを使用する正規の経路はアプリに存在しない。
--
-- 対応:
--   全17テーブルについて、anon・authenticated からDELETEを剥奪する。
--   RLS状態（全17テーブルでRLS有効＋FORCE済み。020で確認済み）は変更しない。
--   将来的にDELETE経路が必要になった場合は、finalize_run・exclude_candidateと
--   同様、呼出者・agency照合付きの関数経由（論理削除やアーカイブ等）で
--   実装することを想定し、直接DELETEの権限は再付与しない方針とする。
-- ============================================================================

DO $$
DECLARE
    v_table text;
BEGIN
    FOR v_table IN
        SELECT c.relname FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
         WHERE n.nspname = 'public' AND c.relkind = 'r'
    LOOP
        EXECUTE format('REVOKE DELETE ON TABLE public.%I FROM anon, authenticated', v_table);
    END LOOP;
END;
$$;
