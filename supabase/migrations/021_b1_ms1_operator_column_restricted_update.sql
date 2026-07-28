-- ============================================================================
-- 021_b1_ms1_operator_column_restricted_update.sql
--
-- 状態: 本番適用済み（本ファイル作成と同一セッションで適用・実測）
--
-- 背景: 田島様2026-07-27 23:41ご指摘6（列単位権限の正しい確認方法）に対応する
--       過程で、operator.role・operator.is_active の自己変更（第3段階1の
--       §5で既報の未是正事項）を、その場で是正した。
--
--   `pg_attribute.attacl` を無条件走査した結果、publicスキーマ全17テーブルの
--   全列で明示的な列ACLは1件も存在しない（すべてNULL）。すなわち、これまでの
--   `has_column_privilege` の結果はすべてテーブル全体の権限に由来しており、
--   列単位で個別に絞り込まれた権限は存在しなかった。
--
--   operator.role・operator.is_active についても同様で、authenticatedの
--   UPDATE権限はテーブル全体に対するものであり、`operator_update_self`
--   ポリシー（USING: auth_user_id=auth.uid()、WITH CHECK: auth_user_id・
--   agency_idの一致のみ検査）と組み合わさることで、本人が自分のroleを
--   admin へ昇格、または is_active を true へ再有効化できる状態だった。
--
--   アプリケーションコードを確認したところ、現時点で operator テーブルへの
--   UPDATE呼出しは1件も存在しない（自己プロフィール編集機能は未実装）。
--   したがって本是正による既存機能への影響はない。
--
-- 対応: テーブル全体のUPDATE権限を剥奪し、氏名・連絡先・免許情報等の
--   自己編集が許容される列のみ列単位でGRANTした。role・is_active・
--   agency_id・auth_user_id・id・created_at は許可列に含めない。
-- ============================================================================

REVOKE UPDATE ON TABLE public.operator FROM authenticated;
GRANT UPDATE (name, email, license_number, license_valid_until, updated_at)
  ON TABLE public.operator TO authenticated;

-- ── 自己検査 ────────────────────────────────────────────────────────────
DO $$
DECLARE v_bad text;
BEGIN
    SELECT string_agg(col,', ') INTO v_bad
      FROM unnest(ARRAY['role','is_active','agency_id','auth_user_id','id','created_at']) AS col
     WHERE has_column_privilege('authenticated','public.operator',col,'UPDATE');
    IF v_bad IS NOT NULL THEN
        RAISE EXCEPTION '021 self-check failed: authenticated still has UPDATE on -> %', v_bad;
    END IF;

    SELECT string_agg(col,', ') INTO v_bad
      FROM unnest(ARRAY['name','email','license_number','license_valid_until','updated_at']) AS col
     WHERE NOT has_column_privilege('authenticated','public.operator',col,'UPDATE');
    IF v_bad IS NOT NULL THEN
        RAISE EXCEPTION '021 self-check failed: authenticated missing expected UPDATE on -> %', v_bad;
    END IF;

    RAISE NOTICE '021 self-check passed';
END;
$$;
