-- ============================================================================
-- 016_b1_ms1_smartphone_token_emergency_lockdown.sql
--
-- 状態: 本番適用済み（2026-07-27。台帳 version 20260727101932）
--
-- 本ファイルは、本番へ実際に実行した5文と一致させている（田島様2026-07-27
-- 23:41ご指摘4「適用済みmigrationは適用後に内容を書き換えない」に対応）。
--
-- 自己検査（RLS有効・FORCE有効・ポリシー0件・残存権限なしの確認）は、
-- 本ファイルには含めない。理由と詳細は
-- `supabase/verification/016_017_post_apply_checks.sql` を参照。
-- 本ファイル単体を新規DBへ通し適用した場合の状態は、上記検証ファイルを
-- 続けて実行することで確認できる。
--
-- 目的: smartphone_confirm_token への未認証アクセスを緊急に遮断する。
--
-- 背景:
--   田島様2026-07-25ご指摘9を推論ではなく実測で検証したところ、未認証（anon）の
--   状態で以下が成立することを確認した（トランザクション内・ROLLBACK済み）。
--     - smartphone_confirm_token の全18件が SELECT で読み取れる
--     - 使用済みトークンの used_at を NULL に戻す UPDATE が成立する（rows_updated=1）
--     - expires_at を延長する UPDATE が成立する
--   すなわち、使用済みトークンを未認証で再利用可能な状態に戻せる。
--
-- 本migrationの位置づけ:
--   田島様2026-07-27ご指示により、本件のみ第3〜第5段階の設計承認を待たず先行適用する。
--   「他の指摘と異なり、設計協議の結論に依存せず単独で適用でき、スマホ確認フローは
--   現在すでに外部から成立しない状態のため、業務への影響もない」とのご判断による。
--
-- 本migrationに含めないもの（第4段階・設計承認後）:
--   - get_smartphone_confirm_status / confirm_smartphone_token / issue_smartphone_confirm_token
--     の3関数。これらは設計協議の対象であり、承認前に作成しない。
--   - したがって本migration適用後、スマホ確認フローはDBレベルで完全に停止する。
--     これは意図した状態であり、第4段階完成まで当該フローは外部利用不可として扱う。
--
-- 破壊される既存経路（いずれも意図的）:
--   - /api/run/[id]/smartphone-token        : authenticated からの直接 INSERT
--   - /api/smartphone-confirm (GET/POST)    : anon からの直接 SELECT / UPDATE
--   両ルートとも createServerSupabaseClient()（ANON KEY）を使用するため、
--   anon または authenticated として実行される。service_role は本migrationの
--   REVOKE 対象外のため、管理経路からの操作は従来どおり可能。
-- ============================================================================

-- ── 1. RLS を有効化する ─────────────────────────────────────────────────
-- ポリシーを1件も作成しないため、RLSの評価対象となるロール（anon・authenticated
-- 等、rolbypassrls=false のロール）からは全行が不可視・変更不可となる。
-- 「RLS有効 かつ ポリシー0件」は deny-all を意味する。
ALTER TABLE public.smartphone_confirm_token ENABLE ROW LEVEL SECURITY;

-- ── 2. RLS を所有者にも適用する（本環境では現時点で実効なし・下記参照）──
-- FORCE ROW LEVEL SECURITY はテーブル所有者にもRLSを適用する設定。
--
-- ただし本環境では、この設定は現時点で実質的な保護を与えない。実測の結果、
-- 本テーブルの所有者は postgres であり、postgres は rolbypassrls = true を
-- 持つ。BYPASSRLS 属性は FORCE より優先されるため、postgres は FORCE の
-- 有無にかかわらずRLSを迂回する。
--   実測: table_owner=postgres, owner_has_bypassrls=t
--
-- したがって「FORCE を付けたので所有者経由の迂回も塞がれた」とは言えない。
-- 実際の保護は下の REVOKE（権限剥奪）が担っている。
--
-- それでも FORCE を付ける理由は、将来テーブルの所有者が BYPASSRLS を持たない
-- ロールへ変更された場合に、その時点で自動的に効き始める多層防御であるため。
-- 現時点での効果を過大に記載しないよう、ここに明記する（020で他16テーブルにも拡張済み）。
--
-- なお、第4段階で追加する SECURITY DEFINER 関数（所有者 postgres）は、
-- 上記のとおり postgres が BYPASSRLS を持つため FORCE 下でも動作する。
-- 実測で確認済み（authenticated から呼出して18件取得できることを確認・ROLLBACK済み）。
-- ただし関数がRLSを迂回する以上、認可は関数内の明示的な照合で行う必要がある。
ALTER TABLE public.smartphone_confirm_token FORCE ROW LEVEL SECURITY;

-- ── 3. テーブル権限を剥奪する ──────────────────────────────────────────
-- RLSは「行の可視性」を制御するが、テーブル権限（GRANT）は別軸の制御であり、
-- 両方を閉じる必要がある。田島様ご指示のとおり PUBLIC を明示的に含める。
--
-- PUBLIC は擬似ロールであり、PUBLIC への付与は全ロールに効果を持つ。
-- anon・authenticated から個別にREVOKEしても、PUBLIC への付与が残っていれば
-- 権限は残存するため、PUBLIC を先に剥奪する。
REVOKE ALL ON TABLE public.smartphone_confirm_token FROM PUBLIC;
REVOKE ALL ON TABLE public.smartphone_confirm_token FROM anon;
REVOKE ALL ON TABLE public.smartphone_confirm_token FROM authenticated;

-- 注: ALL は SELECT/INSERT/UPDATE/DELETE/TRUNCATE/REFERENCES/TRIGGER/MAINTAIN の
--     8権限を含む（MAINTAIN は PostgreSQL 17 で追加。本番は 17.6）。ACL 表記
--     arwdDxtm の末尾 m が MAINTAIN にあたる。
--     TRUNCATE の剥奪は本文で個別に検証せず、has_table_privilege と ACL の
--     実出力で確認する（本番データに対する TRUNCATE の実行試験は行わない）。
